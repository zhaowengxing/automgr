# automgr
一台主机,开多个MGR集群,只要运行1次脚本,一次搞定
多台主机,组建1个MGR集群,只要分别在主机上,各运行1次脚本,一次搞定
修改所有MGR集群mysql配置,只要运行1次脚本,一次搞定
快速增加,缩小MGR集群的容器数量,只要运行1次脚本,一次搞定
新增机器入群,可以自动冷复制数据文件,超级方便
https://github.com/zhaowengxing/automgr MGR自动维护脚本,欢迎大家测试,指导.

当前,MGR功能已经全部可用,proxysql,和keepalived还在更新

MGR容器自动部署,配置,维护持久化+proxysql+keepalived
一个脚本,可以同时在不同主机上运行,可以将不同主机上的docker容器自动部署成,你想要的多个MGR集群.
镜像下载,容器网络桥接,容器编排,mysql持久化,路由添加,集群设置,群组划分,
