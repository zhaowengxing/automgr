#!/bin/bash
set -eo pipefail
#shopt -s nullglob 导致*字符不能输出

#常量REPOSITORY数组的顺序,后面有列位置调用,不要改动列顺序
#编码时VOLUME前都加上了/$name,常量这里不要加;后面有列位置调用,不要改动列顺序
#group需要是两位字符,否则需要修改cnf生成代码
#awk和$@的顺序,从$1开始;数组从[0]开始
#默认网关-1=子网段,如果需要需要重设网关IP,需要修改网段生成代码
#为了root用户可以SSH登录,需要修改/etc/ssh/sshd_config中的PermitRootLogin为yes
#echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
REPOSITORY=(mysql proxysql/proxysql osixia/keepalived)
NET_NAME=mgr_net;MASK=27
COLUMN_HOST_IP=1;COLUMN_GATEWAY=2;COLUMN_CONTAINER_IP=3;COLUMN_APP=4;COLUMN_GROUP=5
APP_NAME_MGR=mysql;APP_NAME_PXY=proxysql;APP_NAME_KEEP=keepalived
MGR_VOLUME=(/mysql:/var/lib/mysql /mysqld:/var/run/mysqld /conf.d:/etc/mysql/conf.d)
REP_USER=rep;REP_PASSWORD=rep123456
MYSQL_ROOT_PASSWORD=root123456



#判断docker 管理程序是否安装
if ! command -v docker > /dev/null;then
	echo docker服务程序没有安装,现在开始安装....
	apt update && apt install -y --no-install-recommends docker.io
	systemctl enable docker
	#将docker服务程序设置成系统自启动
else
	echo docker.io服务程序已安装.
fi

#判断mysql-client-5.7程序是否安装
if ! command -v mysql > /dev/null;then
	echo mysql-client没有安装,现在开始安装....
	apt install -y --no-install-recommends mysql-client-5.7
fi

#下载需要的docker image
for image in "${REPOSITORY[@]}";do
	return_awk="$( docker image ls | awk '$1 == "'"${image}"'" {print $1}')"
	if [ "${return_awk}" == "" ] ; then
		docker pull ${image}
		if [ $? != 0 ]; then
			echo 镜像下载错误,请检查网络或者重新运行脚本! 
			exit 1
		fi
		echo ${image}镜像下载完成!
	else
		echo ${image}镜像已存在.
	fi
done

 
 
#根据mgr_cnf配置文件,运行容器
OLD_IFS="$IFS"
IFS=$'\n'
cnf_line=($(awk '{print $0}' mgr_cnf))
IFS="$OLD_IFS"

#获取容器名称函数;group app container_ip
_get_name(){
	local arry=(${arry_cloum[${COLUMN_CONTAINER_IP}]//./ })
	name="${arry_cloum[${COLUMN_APP}]}"_"${arry_cloum[${COLUMN_GROUP}]}"_${arry[3]}
}

#获取volume对应数组
_get_volume(){
local i=0
local volume=($@)
while [ ${i} -lt ${#volume[@]} ]; do
	host_v[${i}]=/${name}$(echo ${volume[${i}]} | awk '{sub(/:(.)+/,"");print}')
	container_v[${i}]=$(echo ${volume[${i}]} | awk '{sub(/(.)+:/,"");print}')
	let i+=1
done
}

#MGR插件安装及账号设置
_rep_set(){
	local rpl_str="install plugin group_replication soname 'group_replication.so';\
					alter user root identified with mysql_native_password by '"${MYSQL_ROOT_PASSWORD}"';\
					create user ${REP_USER} identified with mysql_native_password by '"${REP_PASSWORD}"';\
					grant replication slave on *.* to ${REP_USER};\
					flush privileges;\
					change master to master_user='"${REP_USER}"',master_password='"${REP_PASSWORD}"' for channel 'group_replication_recovery';"
	echo "${rpl_str}" | "${mysql_str[@]}" &>/dev/null
}




#初始化replication配置文件
_cnf_set(){
	local i=0
	local group_seeds=""
	local group_mgr_cip=()
	group_mgr_cip=($(awk '$'${COLUMN_GROUP}' == "'"${arry_cloum[${COLUMN_GROUP}]}"'" \
				   && $'${COLUMN_APP}' == "'"${APP_NAME_MGR}"'" \
						{print $'${COLUMN_CONTAINER_IP}'}' mgr_cnf))
	while [ ${i} -lt ${#group_mgr_cip[@]} ]; do
		if [ "${group_seeds}" != "" ] ;then
			group_seeds=${group_seeds},
		fi
		group_seeds+=${group_mgr_cip[${i}]}:33061
		let i+=1
	done
	sed -i '/^server-id/c server-id='${arry_cloum[${COLUMN_CONTAINER_IP}]//./}'' mgr.cnf
	sed -i '/^loose-group_replication_group_name/c loose-group_replication_group_name=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa'${arry_cloum[${COLUMN_GROUP}]}'' mgr.cnf
	sed -i '/^loose-group_replication_local_address/c loose-group_replication_local_address='${arry_cloum[${COLUMN_CONTAINER_IP}]}':33061' mgr.cnf
	sed -i '/^loose-group_replication_group_seeds/c loose-group_replication_group_seeds='${group_seeds}'' mgr.cnf
	cp mgr.cnf ${host_v[2]}
	chown -R 999:999 ${host_v[2]}/mgr.cnf
	docker restart ${name} > /dev/null
}


#初始化mysql_volume;mysql容器是999:999的uid:gid来启动的
_initial_mysql_volume(){
	local i=0
	while [ ${i} -lt ${#host_v[@]} ]; do
		mkdir -p ${host_v[${i}]}
		chown 999:999 ${host_v[${i}]}
		let i+=1
	done
}


# 创建容器;
_create_mysql_container(){
	i=0;dockerv=
	while [ ${i} -lt ${#host_v[@]} ];do
		dockerv+=" -v ${host_v[${i}]}:${container_v[${i}]}"
		let i+=1
	done
	docker_run=(docker run 	-d --name ${name} \
				--net ${NET_NAME} \
				--ip ${arry_cloum[${COLUMN_CONTAINER_IP}]} \
				--restart=always \
				-e MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD} \
				${dockerv} ${REPOSITORY[0]})
	${docker_run[@]}
	
	#判断mysqld容器启动成功

	for i in {6..0}; do
		if echo 'select 1' | "${mysql_str[@]}" &>/dev/null; then
			break
		fi
		echo ${arry_cloum[${COLUMN_HOST_IP}]}主机上的容器${arry_cloum[${COLUMN_CONTAINER_IP}]}正在启动mysqld服务!
		sleep 10
	done
	if [ $i = 0 ]; then
		echo >&2 'mysqld容器启动失败.'
		exit 1
	fi
}


echo '本次运行脚本主要目的:[1/2/3]?'
echo 1 修改mysql配置文件;存在的容器修改,不存在的创建
echo 2 复制数据;创建不存在的容器时,提示数据复制
echo 3 引导集群启动;
read main_cmd

#检查mgr_cnf文件每行设置;
line_i=1;while [ ${line_i} -lt ${#cnf_line[@]} ]; do
#取到的行数据,cnf_line数组是从[0]开始,[0]是列表名行,不需要循环

	#取到的每行的列数组arry_cloum也是从[0]开始,为了和awk一致,将[0]用字符占位
	arry_cloum=('zw' ${cnf_line[$line_i]})
	echo ------应用"${arry_cloum[${COLUMN_CONTAINER_IP}]}"配置------
	

	return_awk=$(ifconfig | awk '/'${arry_cloum[${COLUMN_HOST_IP}]}'/{print $0}')
	if [ "${return_awk}" != "" ]; then 
	#判断host_ip,是本机

		return_awk=$(docker network ls |awk '$2 == "'"${NET_NAME}"'"{print $0}')
		if [ "${return_awk}" == "" ]; then
		#判断docker network "${NET_NAME}"是否存在
		
			arry_local_ip=(${arry_cloum[${COLUMN_GATEWAY}]//./ })
			docker network create --subnet=${arry_local_ip[0]}.${arry_local_ip[1]}.${arry_local_ip[2]}.$((${arry_local_ip[3]}-1))/${MASK} \
			--gateway ${arry_cloum[${COLUMN_GATEWAY}]} ${NET_NAME}
		fi

		#找到同一group组的主机IP,创建路由,保证同组,在不同主机的容器通讯
		group_host=($(awk '$'${COLUMN_GROUP}' == "'"${arry_cloum[${COLUMN_GROUP}]}"'"{print $'${COLUMN_HOST_IP}'}' mgr_cnf))
		j=0;k=0;df_host=()
		while [ ${j} -lt ${#group_host[@]} ];do
			if [ ${group_host[${j}]} != ${arry_cloum[${COLUMN_HOST_IP}]} ];then
			#找到同组IP
				return_awk=$(echo "${df_host[@]}" | awk '/'${group_host[${j}]}'/ {print $0}')
				if [ "${return_awk}" == "" ]; then
				#df_host数组中没有的,同组IP
					df_host[${k}]=${group_host[${j}]}
				fi
				let k+=1
			fi
			let j+=1
		done

		#判断路由条目是否存在;手工删除格式route del -net 192.168.21.0/27
		j=0
		while [ ${j} -lt ${#df_host[@]} ];do
			arry=$(awk '$'${COLUMN_GROUP}' == "'"${arry_cloum[${COLUMN_GROUP}]}"'" \
				&& $'${COLUMN_HOST_IP}' == "'"${df_host[${j}]}"'" \
				{print $'${COLUMN_GATEWAY}'}' mgr_cnf )
			arry=(${arry[0]//./ })
			#返回的同组,同一df_host的网关有多个重复值,只需要一个来生成网段
			
			return_awk=($(route | awk '$2 == "'"${df_host[${j}]}"'" {print $0}'))
			if [ "${return_awk}" == "" ]; then
			# 路由不存在,创建路由规则;需要修改/etc/sysctl.conf文件,否则创建了路由,也不能通讯
			# 重启后依然有效,需要修改/etc/sysconfig/static-routes
				sed -i '/net\.ipv4\.ip_forward/c net.ipv4.ip_forward = 1' /etc/sysctl.conf
				route_str="${arry[0]}.${arry[1]}.${arry[2]}.$((${arry[3]}-1))/${MASK} gw ${df_host[${j}]}"
				route add -net ${route_str}
				if [ ! -e /etc/sysconfig/static-routes ]; then
					mkdir -p /etc/sysconfig
					echo "any net ""${route_str}" > /etc/sysconfig/static-routes
				else
					return_awk=$(awk '/any net '${arry[0]}'\.'${arry[1]}'\.'${arry[2]}'\.'$((${arry[3]}-1))'/{print $0}' /etc/sysconfig/static-routes)
					if [ "${return_awk}" == "" ]; then
						echo "any net ""${route_str}" >> /etc/sysconfig/static-routes
					else
						sed -i '/any net '${arry[0]}'\.'${arry[1]}'\.'${arry[2]}'\.'$((${arry[3]}-1))'/c any net '"${route_str}"'' /etc/sysconfig/static-routes
					fi
				fi
				
				if [ "$?" == 0 ];then
					echo ${arry_cloum[${COLUMN_GROUP}]}集群的\
						${arry_cloum[${COLUMN_HOST_IP}]}到${df_host[${j}]}路由规则创建成功!
				fi
			fi	
			let j+=1
		done
		
		
		
		#判断本行涉及的APP类型
		_get_name
		case ${arry_cloum[${COLUMN_APP}]} in 
			${APP_NAME_MGR})
			#mysql容器类型
				_get_volume "${MGR_VOLUME[@]}"
				mysql_str=( mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${arry_cloum[${COLUMN_CONTAINER_IP}]} )
				return_awk=($(docker ps -a | awk '/(.)+'${name}'$/{print $0}'))
				if [ "${return_awk}" != "" ]; then
				#容器存在
					return_awk=($(docker ps -a | awk '/(.)+(Up )+(.)+'${name}'$/{print $0}'))
					if [ "${return_awk}" = "" ]; then
					#不在运行状态
						if [ "${main_cmd}" == 1 ];then
							_cnf_set
							docker start ${name} >/dev/null
						fi
					else
					#在运行状态
						if [ "${main_cmd}" == 1 ];then
							_cnf_set
							docker restart ${name} >/dev/null
						fi
					fi
				else
				#容器不存在
					
					if [ ! -d /${name} ]; then
					#主机volume文件夹不存在
						_initial_mysql_volume
						_create_mysql_container
						_rep_set
						_cnf_set
					else
					#主机volume文件夹存在;
						echo ${arry_cloum[${COLUMN_HOST_IP}]}主机上,已存在/${name}的数据文件夹,请选择你需要的操作:
						echo 1 保留数据,重建容器
						echo 2 清空数据,重建容器
						read answer
						case ${answer} in
							1) 	
								_create_mysql_container
								_cnf_set
								;;
							2) rm /${name} -r
								_initial_mysql_volume
								_create_mysql_container
								_rep_set
								_cnf_set
								;;
						esac
					fi


					if [ "${main_cmd}" == 2 ];then
					#复制数据文件;
						datasize=($(du -sh /${name}))
						echo "${arry_cloum[${COLUMN_HOST_IP}]}主机上,容器/${name}的数据文件夹总容量为:${datasize[0]},是否需要从其他容器,拷贝数据文件[y/n]?"
						read answer
						case ${answer} in
							y) 	
								echo 请确认源文件夹不在使用,ssh配置中,已经允许root登录
								echo 请输入源容器ip:
								read answer_ip
								
								local_name=(${name//_/ })
								return_awk=$(awk '$'${COLUMN_CONTAINER_IP}' == "'"${answer_ip}"'"{print $'${COLUMN_HOST_IP}'}' mgr_cnf)
								sourceip=(${answer_ip//./ })
								sourcename=${local_name[0]}_${local_name[1]}_${sourceip[3]}
								answer_cmd="scp -r root@${return_awk}:/${sourcename}/* /${name}"
								if [ "${answer_cmd}" != "" ]; then
									docker stop ${sourcename} ${name} >/dev/null
									${answer_cmd}
									chown -R 999:999 /${name}
									rm ${host_v[0]}/auto.cnf
									_cnf_set
									docker start ${sourcename}  >/dev/null
								fi
								;;
							n) ;;
						esac
					fi
				fi
				
				#引导集群的mysql容器MEMBER_ROLE=primary;如果不是引导的本群组第一个mysql,需要手动重启跳过的mysql容器
				if [ "${main_cmd}" == 3 ];then
				#引导集群启动
					already_bootstrap=
					for i in "${already_bootstrap_group[@]}";do
						if [ "${i}" == "${arry_cloum[${COLUMN_GROUP}]}" ];then
						#当前行的群组,已经进行过引导
							already_bootstrap=yes;break
						fi
					done
					if [ "${already_bootstrap}" != "yes" ] ;then
					#当前行的群组,没有进行过引导
						echo 如果对已存在MEMBER_ROLE=primary的群组进行引导,将导致人为脑裂!
						echo 请确认${arry_cloum[${COLUMN_GROUP}]}集群中,所有MGR成员的member_state都为offline,再进行引导!
						echo 1 引导${arry_cloum[${COLUMN_GROUP}]}集群启动
						echo 2 不引导
						read answer
						case ${answer} in
							1)  mgr_boot="set global group_replication_bootstrap_group=on;\
										start group_replication;\
										set global group_replication_bootstrap_group=off;"
								echo "${mgr_boot}" | "${mysql_str[@]}" &>/dev/null
								already_bootstrap_group=(${already_bootstrap_group[@]} ${arry_cloum[${COLUMN_GROUP}]})
								;;
							2) 	
								;;
						esac
					else
					#当前行的群组,已经进行过引导;start group_replication当前mysql容器
						echo 'start group_replication;' | "${mysql_str[@]}" &>/dev/null
					fi
				fi
				;;
			${APP_NAME_PXY})
				# echo proxysql
				;;
			${APP_NAME_KEEP})
				# echo keepalived
				;;
		esac
	fi
	let line_i+=1
done
echo 脚本运行结束
