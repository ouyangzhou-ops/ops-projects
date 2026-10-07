# 高可用 Web 集群搭建与自动化运维 —— 完整实施手册

> 与 README 配套的逐步操作手册。按「环境初始化 → 负载均衡 → 数据 → 基础设施 → 自动化 → 监控 → 演练」顺序，每个阶段含操作步骤与验证命令。

## 0. 环境规划

| 角色 | 主机名 | IP | 组件 |
|---|---|---|---|
| LB1（主） | lb-1 | 192.168.194.128 | LVS + Keepalived（MASTER，priority 150） |
| LB2（备） | lb-2 | 192.168.194.129 | LVS + Keepalived（BACKUP，priority 100） |
| Web1 | web-1 | 192.168.194.133 | Nginx（双虚拟主机） |
| Web2 | web-2 | 192.168.194.134 | Nginx（双虚拟主机） |
| 综合服务器 | max | 192.168.194.135 | NFS + BIND DNS + MySQL + Ansible + Prometheus + Grafana + 堡垒机 |

- 操作系统：CentOS 7（VMware Workstation，NAT 网段 192.168.194.0/24）
- VIP（虚拟 IP）：192.168.194.100
- 域名：www.ouyang.com / www.zhou.com（均解析到 VIP）

---

## 1. 环境初始化（5 台都执行）

### 1.1 主机名与 hosts
```bash
hostnamectl set-hostname lb-1        # 各台对应 lb-1/lb-2/web-1/web-2/max
cat >> /etc/hosts <<EOF
192.168.194.128 lb-1
192.168.194.129 lb-2
192.168.194.133 web-1
192.168.194.134 web-2
192.168.194.135 max
EOF
```

### 1.2 静态 IP（克隆出的机器默认 DHCP，需手动改）
```bash
vi /etc/sysconfig/network-scripts/ifcfg-ens33
# 追加/修改：
BOOTPROTO="static"
ONBOOT="yes"
IPADDR="192.168.194.133"      # 各台对应自己的 IP
NETMASK="255.255.255.0"
GATEWAY="192.168.194.2"
DNS1="192.168.194.135"        # 内网 DNS 指向 max，最后再配
systemctl restart network
ip addr | grep inet           # 确认 IP 生效
```
> **克隆坑**：克隆出来的机器网卡会带原机的 UUID，`systemctl restart network` 前若提示冲突，删除 ifcfg-ens33 里的 UUID 行或使用 `nmcli con` 重新生成。

### 1.3 关闭防火墙与 SELinux
```bash
systemctl stop firewalld && systemctl disable firewalld
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
```

### 1.4 更新 yum 源（换国内源，下载提速）
```bash
mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
yum clean all && yum makecache
```

---

## 2. LVS + Keepalived 负载均衡与高可用（LB1/LB2）

### 2.1 安装
```bash
yum install -y ipvsadm keepalived
```

### 2.2 配置（LB1 用仓库 keepalived-lb1.conf，LB2 用 keepalived-lb2.conf）
差异只有三处：`router_id`、`state`、`priority`。

### 2.3 启动并验证
```bash
systemctl enable --now keepalived
ip addr | grep 192.168.194.100    # LB1 上应出现 VIP（MASTER 持有）
ipvsadm -L -n                     # 查看 LVS 规则与两台 real_server
# TCP  192.168.194.100:80 rr
#   -> 192.168.194.133:80  Masq/DR
#   -> 192.168.194.134:80  Masq/DR
```

---

## 3. RS 配置：后端绑定 VIP（Web1/Web2 必须，否则收不到流量）

### 3.1 临时绑定 + 持久化
```bash
# 临时生效（重启丢失）
ip addr add 192.168.194.100/32 dev lo
ip link set lo up

# 持久化：写入 ifcfg-lo:0（见仓库 ifcfg-lo0.conf）
cat > /etc/sysconfig/network-scripts/ifcfg-lo:0 <<EOF
DEVICE=lo:0
IPADDR=192.168.194.100
NETMASK=255.255.255.255
ONBOOT=yes
NAME=loopback
EOF
```

### 3.2 抑制 ARP 响应（核心，缺了会响应 VIP 的 ARP 导致冲突）
```bash
cat > /etc/sysctl.d/arp.conf <<EOF
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.lo.arp_ignore = 1
net.ipv4.conf.lo.arp_announce = 2
EOF
sysctl -p /etc/sysctl.d/arp.conf
```

> **为什么必须配**：DR 模式下 VIP 同时存在于 LB 和 RS 的 lo 上，若不抑制 ARP，RS 会响应 VIP 的 ARP 请求，客户端拿到 RS 的 MAC 后流量绕过 LVS，负载均衡失效。

---

## 4. Nginx Web 服务器（Web1/Web2）

### 4.1 安装
```bash
yum install -y nginx
```

### 4.2 虚拟主机配置
项目采用 `conf.d` 目录方式（nginx.conf 的 http 块已 `include /etc/nginx/conf.d/*.conf`，业务配置放独立文件便于管理和区分）：
```bash
cp 仓库的 nginx-vhost.conf /etc/nginx/conf.d/vhost.conf
mkdir -p /data/web/ouyang /data/web/zhou
echo '<h1>Welcome to Ouyang</h1>' > /data/web/ouyang/index.html
echo '<h1>Welcome to Zhou</h1>'  > /data/web/zhou/index.html
nginx -t          # 语法检查
systemctl enable --now nginx
```

### 4.3 验证
```bash
# 先在本机 hosts 临时加域名解析，或直接用 Host 头测试：
curl -H "Host: www.ouyang.com" http://127.0.0.1/
curl -H "Host: www.zhou.com" http://127.0.0.1/
```

---

## 5. NFS 共享存储（max 服务器 + Web 客户端）

### 5.1 max 上安装并配置
```bash
yum install -y nfs-utils
mkdir -p /data/web
cp 仓库的 nfs-exports /etc/exports    # 共享 /data/web 给 133/134
exportfs -rv
systemctl enable --now nfs-server rpcbind
```

### 5.2 Web 客户端挂载
```bash
yum install -y nfs-utils
mount -t nfs 192.168.194.135:/data/web /data/web
# 开机自动挂载
echo "192.168.194.135:/data/web /data/web nfs4 defaults,_netdev 0 0" >> /etc/fstab
mount -a
df -h | grep data/web
```

### 5.3 验证数据一致性
```bash
# 在 web-1 上写文件，web-2 立即可见
echo "test" > /data/web/ouyang/index.html
cat /data/web/ouyang/index.html     # web-2 上执行
```

---

## 6. DNS 域名解析（max 服务器）

### 6.1 安装 BIND
```bash
yum install -y bind bind-utils
```

### 6.2 配置
```bash
cp 仓库的 named.conf /etc/named.conf
cp 仓库的 ouyang.com.zone /var/named/ouyang.com.zone
cp 仓库的 zhou.com.zone /var/named/zhou.com.zone
named-checkconf && named-checkzone ouyang.com /var/named/ouyang.com.zone   # 语法检查
systemctl enable --now named
```

### 6.3 客户端指向 DNS（5 台 /etc/resolv.conf）
```bash
echo "nameserver 192.168.194.135" > /etc/resolv.conf
nslookup www.ouyang.com            # 应解析出 192.168.194.100
nslookup www.zhou.com
```

---

## 7. MySQL 数据库（max 服务器）

### 7.1 安装初始化
```bash
yum install -y mariadb-server
systemctl enable --now mariadb
mysql_secure_installation
```

### 7.2 建库授权（业务账号，供 Web 连接）
```sql
CREATE DATABASE IF NOT EXISTS webdb DEFAULT CHARSET utf8mb4;
CREATE USER 'web'@'192.168.194.%' IDENTIFIED BY '<密码>';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'192.168.194.%';
FLUSH PRIVILEGES;
```

### 7.3 验证远程连接（web-1 上）
```bash
yum install -y mysql
mysql -h 192.168.194.135 -u web -p -e "SHOW DATABASES;"
```

---

## 8. 堡垒机 + tcp wrappers 访问控制（max 服务器）

> 目标：只允许 max（堡垒机）SSH 登录 Web1/Web2，其他来源一律拒绝。

### 8.1 SSH 服务端配置（Web1/Web2）
```bash
# /etc/ssh/sshd_config 确保 UseDNS no；重启 sshd
systemctl restart sshd
```

### 8.2 tcp wrappers（Web1/Web2）
```bash
cat > /etc/hosts.allow <<EOF
sshd: 192.168.194.135
EOF
cat > /etc/hosts.deny <<EOF
ALL: ALL
EOF
```

### 8.3 验证
```bash
# 从 max SSH 到 web-1/web-2：允许
ssh web-1
# 从其他机器（如 lb-1）SSH 到 web-1：拒绝（Permission denied）
```

---

## 9. Ansible 自动化运维（max 服务器）

### 9.1 安装（需 epel 源）
```bash
yum install -y epel-release
yum install -y ansible
```

### 9.2 主机清单
```bash
cp 仓库的 ansible-hosts.ini /etc/ansible/hosts
# 分组：lb（2 台）/ web（2 台）/ db（1 台）
```

### 9.3 SSH 免密
```bash
ssh-keygen -t rsa -N ""
ssh-copy-id root@192.168.194.128
ssh-copy-id root@192.168.194.129
ssh-copy-id root@192.168.194.133
ssh-copy-id root@192.168.194.134
# max 本机免密（自己管理自己）
ssh-copy-id root@192.168.194.135
```

### 9.4 验证
```bash
ansible all -m ping                    # 全部 pong
ansible web -m shell -a "hostname"     # 分组执行
ansible all -m shell -a "free -h"      # 批量收集内存
```

---

## 10. Prometheus + Grafana 监控（max 服务器）

### 10.1 node-exporter（5 台都部署）
```bash
wget https://github.com/prometheus/node_exporter/releases/download/v1.6.0/node_exporter-1.6.0.linux-amd64.tar.gz
tar xf node_exporter-1.6.0.linux-amd64.tar.gz -C /opt
# 配置 systemd 服务后启动
curl http://127.0.0.1:9100/metrics | head    # 验证指标
```

### 10.2 Prometheus（二进制部署）
```bash
wget https://github.com/prometheus/prometheus/releases/download/v2.45.0/prometheus-2.45.0.linux-amd64.tar.gz
tar xf prometheus-2.45.0.linux-amd64.tar.gz -C /opt
cp 仓库的 prometheus.yml /opt/prometheus/prometheus.yml
# 配置 systemd 服务后启动，验证 http://192.168.194.135:9090/targets 5 个 target 全 UP
```

### 10.3 Grafana
```bash
# 方式一：rpm 离线安装（下载慢时的兜底，见排障记录）
yum localinstall -y grafana-enterprise-9.1.2-1.x86_64.rpm
systemctl enable --now grafana-server
# 方式二：docker
docker run -d --name grafana -p 3000:3000 grafana/grafana
```
1. 登录 `http://192.168.194.135:3000`（admin/admin）
2. 添加数据源 Prometheus，URL `http://192.168.194.135:9090`
3. 导入仪表盘 **1860**（Node Exporter Full），选择数据源

---

## 11. 压测与高可用演练

### 11.1 ab 压力测试
```bash
yum install -y httpd-tools
ab -n 10000 -c 1000 http://192.168.194.100/
# 重点看：Requests per second、Time per request、Failed requests（必须为 0）
```

### 11.2 主备切换演练
```bash
# 客户端持续访问
while true; do curl -s http://www.ouyang.com/ >/dev/null && echo OK; sleep 1; done

# 停掉 LB1 的 keepalived，模拟主节点故障
systemctl stop keepalived        # 在 lb-1 执行
ip addr | grep 192.168.194.100   # lb-2 上观察：VIP 约 8 秒内漂移过来
ipvsadm -L -n                    # lb-2 的规则接管流量
# 观察客户端循环：全程 OK，无中断

# 恢复：启动 lb-1 的 keepalived，VIP 自动漂回（MASTER 抢占）
```

---

## 12. 排障记录

### 12.1 NAT 模式 curl 挂起
- **现象**：VIP 能 ping 通，curl 卡住（见 README）
- **原因**：客户端与 RS 同网段，回包绕过 LVS 直连客户端，客户端因源 IP 不匹配丢包
- **解决**：改 DR 模式

### 12.2 DR 模式仍挂起
- **原因**：RS 的 lo 没绑 VIP，内核丢弃目的 IP 为 VIP 的包
- **解决**：`ip addr add 192.168.194.100/32 dev lo` + ifcfg-lo:0 持久化

### 12.3 restart network 后 VIP 丢失
- **原因**：临时配置不持久
- **解决**：写 ifcfg-lo:0（见第 3 节）

### 12.4 Grafana rpm 下载慢/失败
- **现象**：在线下载 grafana rpm 卡住或返回 404
- **解决**：换可用镜像或下载 rpm 包到 /opt 后 `yum localinstall`；兜底用 docker 起 Grafana

### 12.5 克隆机器网卡冲突
- **现象**：restart network 报错或 IP 不对
- **解决**：删 ifcfg-ens33 的 UUID 行，重启 network
