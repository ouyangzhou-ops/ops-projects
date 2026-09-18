# 高可用 Web 集群搭建与自动化运维

模拟企业 Web 项目实际需求，构建高可用、高性能的 Web 集群系统。部署 LVS 负载均衡系统 + Keepalived 高可用软件，后端采用 Nginx 作为 Web 服务器，搭建内部 Prometheus 监控系统，通过 Ansible 实现集群全流程自动化运维。

## 环境

- 6 台 Linux 虚拟机（VMware Workstation），CentOS 7
- 静态 IP、DNS 服务器、主机名统一规划
- 项目拓扑使用 ProcessOn 绘制并标注 IP

## 核心技术

LVS + Keepalived + Nginx + Ansible + Prometheus + Grafana + NFS + MySQL + DNS

| 模块 | 实现 |
|---|---|
| 负载均衡与高可用 | Nginx 7 层负载均衡（轮询 RR）+ Keepalived 单 VIP 高可用，主节点故障 10s 内自动切换 |
| 数据一致性 | NFS 共享网页目录，Web 服务器数据实时同步 |
| 自动化运维 | Ansible 主机清单 + SSH 免密，批量命令执行、配置管理、应用部署 |
| 监控体系 | Prometheus + Node Exporter + mysqld Exporter + Grafana 可视化 |
| 基础设施 | DNS 域名解析、MySQL 数据库、堡垒机 + tcp wrappers 访问控制 |

## 核心成果

- Web 集群 7*24 小时高可用，主节点故障 10s 内自动切换，服务无中断
- Ansible 全流程自动化运维，减少 80% 手动操作量
- 全链路监控体系，实现故障早发现、早定位
- 并发 1000 压力测试通过，集群响应正常、无卡顿、无宕机

## 说明

本项目基于 VMware 虚拟机环境实施，部署脚本与配置文件整理中。
