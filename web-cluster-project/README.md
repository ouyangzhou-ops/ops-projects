# 高可用 Web 集群搭建与自动化运维

模拟企业 Web 项目实际需求，构建高可用、高性能的 Web 集群系统。部署 LVS 负载均衡 + Keepalived 高可用，后端 Nginx 作为 Web 服务器，搭建内部 Prometheus 监控，通过 Ansible 实现集群自动化运维。

## 架构

```
客户端
  │
  ▼
DNS (192.168.194.135) 解析域名 → VIP 192.168.194.100
  │
  ├─ LB1 (192.168.194.128)  MASTER  priority 150
  └─ LB2 (192.168.194.129)  BACKUP   priority 100
       │
       LVS DR 模式 + Keepalived VIP 漂移
       │
  ├─ Web1 (192.168.194.133)  Nginx 虚拟主机
  └─ Web2 (192.168.194.134)  Nginx 虚拟主机
       │
  NFS 共享存储 (192.168.194.135:/data/web)
       │
  MySQL (192.168.194.135) 后端数据存储
       │
  Ansible (192.168.194.135) 批量管理 5 台
  堡垒机 + tcp wrappers 管控 SSH 访问
  Prometheus + Grafana 监控全节点
```

## 核心技术

LVS + Keepalived + Nginx + Ansible + Prometheus + Grafana + NFS + MySQL + DNS

| 模块 | 实现 |
|---|---|
| 负载均衡与高可用 | LVS DR 模式（轮询 RR）+ Keepalived 单 VIP 高可用，主节点故障 8s 内自动切换 |
| 数据一致性 | NFS 共享网页目录，Web 服务器数据实时同步 |
| 自动化运维 | Ansible 主机分组 + SSH 免密，批量命令、配置下发 |
| 监控体系 | Prometheus + Node Exporter + Grafana 可视化（仪表盘 1860） |
| 基础设施 | DNS 域名解析、MySQL 数据库、堡垒机 + tcp wrappers 访问控制 |

## 配置文件说明

| 文件 | 说明 |
|---|---|
| `keepalived-lb1.conf` | Keepalived + LVS DR 模式配置（lb2 仅 state/priority 不同） |
| `nginx-vhost.conf` | Nginx 虚拟主机（www.ouyang.com / www.zhou.com） |
| `prometheus.yml` | Prometheus 抓取 5 个 node-exporter |
| `ansible-hosts.ini` | Ansible 主机分组（lb/web/db） |
| `nfs-exports` | NFS 共享配置 |
| `named.conf` + `*.zone` | BIND DNS 解析配置 |

## 关键技术点

### LVS DR 模式三要素
1. LB 上 keepalived 绑定 VIP
2. RS 上 lo 接口绑定 VIP（/32）
3. RS 上 `arp_ignore=1`, `arp_announce=2` 抑制 ARP 响应

三者缺一不可，否则后端收到目的 IP 为 VIP 的包会被内核丢弃。

### NAT vs DR
- NAT：回包必须经 LVS 做 SNAT，要求 RS 和客户端不同网段
- DR：LVS 只改目的 MAC，回包直接回客户端，性能高，生产主流

### 高可用切换
停 MASTER 的 keepalived，VIP 在 8 秒内漂移到 BACKUP，业务不中断。

## 排障记录

1. **curl 挂起但 VIP 能 ping 通（NAT 模式）**
   - 原因：客户端与 RS 同网段，回包绕过 LVS 直连客户端，客户端收到源 IP 不匹配的包直接丢弃
   - 解决：改 DR 模式

2. **DR 模式 curl 仍挂起**
   - 原因：RS 的 lo 没绑 VIP，内核收到目的 IP 为 VIP 的包直接丢弃
   - 解决：`ip addr add VIP/32 dev lo` + 写 ifcfg-lo:0 持久化

3. **restart network 后 VIP 丢失**
   - 原因：`ip addr add` 是临时配置，restart network 不执行 rc.local
   - 解决：写 `/etc/sysconfig/network-scripts/ifcfg-lo:0` 持久化

## 验证

```bash
# 访问两个站点
curl http://www.ouyang.com/
curl http://www.zhou.com/

# Ansible 批量管理
ansible all -m ping
ansible all -m shell -a "free -h"

# 监控面板
http://192.168.194.135:3000  (Grafana, 仪表盘 1860)
http://192.168.194.135:9090  (Prometheus)
```
