# K8s 云原生 Web 应用部署实践 —— 完整实施手册

> 与 README 配套的逐步操作手册。每个阶段含「操作步骤 + 关键命令 + 验证方式」。未注明具体值的参数请按实际环境替换，本项目中已确定的 IP 直接使用。

## 0. 环境规划

| 角色 | 主机名 | IP | 组件 |
|---|---|---|---|
| master | k8s-master | 192.168.194.130 | kube-apiserver / controller-manager / scheduler / etcd / Calico / ingress-nginx / metrics-server / Prometheus / Grafana |
| node-1 | k8s-node-1 | 192.168.194.131 | kubelet / kube-proxy / Calico |
| node-2 | k8s-node-2 | 192.168.194.132 | kubelet / kube-proxy / Calico |

- 操作系统：CentOS 7.9（VMware Workstation 虚拟机，NAT 网段 192.168.194.0/24）
- Kubernetes：v1.23.17（kubeadm 部署）

---

## 1. 三节点基础环境初始化（三台都执行）

### 1.1 主机名与 hosts
```bash
hostnamectl set-hostname k8s-master   # node 分别为 k8s-node-1 / k8s-node-2
cat >> /etc/hosts <<EOF
192.168.194.130 k8s-master
192.168.194.131 k8s-node-1
192.168.194.132 k8s-node-2
EOF
```

### 1.2 关闭防火墙与 SELinux
```bash
systemctl stop firewalld && systemctl disable firewalld
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
```

### 1.3 关闭 swap（kubelet 要求）
```bash
swapoff -a
sed -i '/swap/d' /etc/fstab
```

### 1.4 加载内核模块与系统参数
```bash
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
```

### 1.5 时间同步
```bash
yum install -y chrony && systemctl enable --now chronyd
timedatectl set-timezone Asia/Shanghai
```

---

## 2. 容器运行时：Docker（三台都执行）

### 2.1 安装 Docker（配置国内镜像加速）
```bash
yum install -y yum-utils
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
```

> 注意：kubeadm v1.23 仍可直接使用 Docker 运行时（无需 cri-dockerd）。

---

## 3. 安装 kubeadm / kubelet / kubectl（三台都执行，版本保持一致）

### 3.1 配置 Kubernetes yum 源（阿里云）
```bash
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=0
EOF
```

### 3.2 安装指定版本并锁定
```bash
yum install -y kubeadm-1.23.17 kubelet-1.23.17 kubectl-1.23.17
systemctl enable --now kubelet   # 此时启动会失败属正常，kubeadm init 后会恢复
```

---

## 4. 集群初始化（仅在 master 执行）

### 4.1 kubeadm init
```bash
kubeadm init \
  --kubernetes-version=v1.23.17 \
  --apiserver-advertise-address=192.168.194.130 \
  --pod-network-cidr=<Pod网段，如 192.168.0.0/16，需与 Calico 一致> \
  --image-repository=registry.aliyuncs.com/google_containers \
  --service-cidr=10.96.0.0/12
```
- `--image-repository` 指定国内镜像仓库，解决 gcr.io 拉取失败
- `--apiserver-advertise-address` 指定 master 通信 IP
- `--pod-network-cidr` 必须与后续 Calico 的网段一致，否则 Pod 网络不通

初始化成功后输出两段关键信息：`kubeadm join` 命令 和 `kubeconfig` 配置命令。

### 4.2 配置 kubectl（master）
```bash
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
kubectl get nodes   # master 状态 NotReady 属正常，等网络插件
```

### 4.3 加入 node 节点（node-1 / node-2 执行）
```bash
kubeadm join 192.168.194.130:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```
> token 默认 24h 过期。过期后用 `kubeadm token create --print-join-command` 重新生成。

### 4.4 验证节点状态
```bash
kubectl get nodes
# 三节点均为 NotReady（等待 Calico）
```

---

## 5. 部署 Calico 网络插件（master）

### 5.1 安装
```bash
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
# 如网络受限可先下载到本地再 apply
kubectl apply -f calico.yaml
```

### 5.2 验证
```bash
kubectl get pods -n kube-system -o wide   # calico-node 每节点一个，Running
kubectl get nodes                          # 三节点全部 Ready
```

> **选型说明**：Calico 基于 BGP 大规模路由，适合几千台以上的生产环境；Flannel 更轻量（VXLAN 封装），适合小规模。本项目选 Calico。

---

## 6. 业务镜像制作与分发

### 6.1 编写 Dockerfile（见仓库 Dockerfile）
```dockerfile
FROM nginx:1.25
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

### 6.2 构建镜像
```bash
docker build -t webapp:v1 .          # 初始版本
# 修改 index.html 后重新构建 v2，用于滚动更新演示
docker build -t webapp:v2 .
```

### 6.3 分发到各节点
```bash
# 方式一：save/load（集群内无镜像仓库时常用）
docker save webapp:v1 -o webapp-v1.tar
# 将 tar 拷贝到 node-1/node-2 后：
docker load -i webapp-v1.tar

# 方式二：搭建私有仓库 registry，docker push/pull
```

---

## 7. 应用部署：Deployment / Service / Ingress

### 7.1 Deployment（多副本 + 资源限制）
```bash
kubectl apply -f webapp.yaml
kubectl get pods -o wide        # 3 副本 Running
kubectl get deployment webapp
```

### 7.2 Service（ClusterIP 内部访问）
```bash
kubectl apply -f svc.yaml
kubectl get svc webapp-svc
kubectl get endpoints webapp-svc   # 3 个 Pod IP
# 集群内验证
kubectl run -it --rm test --image=busybox -- sh
wget -qO- http://webapp-svc:80
```

### 7.3 安装 ingress-nginx 控制器
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.0/deploy/static/provider/cloud/deploy.yaml
kubectl get pods -n ingress-nginx
```

### 7.4 将控制器 Service 暴露为 NodePort
```bash
kubectl get svc -n ingress-nginx   # 默认 ClusterIP
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec":{"type":"NodePort"}}'
kubectl get svc -n ingress-nginx   # 记下对外端口，本项目为 30710
```

### 7.5 创建 Ingress 规则
```bash
kubectl apply -f ingress.yaml
kubectl get ingress            # 确认 ADDRESS 不为空
kubectl describe ingress webapp-ingress
```

### 7.6 客户端域名解析（Windows hosts）
```
# C:\Windows\System32\drivers\etc\hosts 追加
192.168.194.130 web.ouyang.com
```
浏览器访问 `http://web.ouyang.com:30710` 验证。

---

## 8. HPA 弹性伸缩

### 8.1 安装 metrics-server（HPA 的数据来源）
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# 若证书校验失败，追加 --kubelet-insecure-tls 参数
kubectl top nodes    # 能输出节点指标即正常
```

### 8.2 创建 HPA
```bash
kubectl apply -f hpa.yaml
kubectl get hpa
# NAME     REFERENCE          TARGETS   MINPODS   MAXPODS
# webapp   Deployment/webapp  0%/50%    1         5
```

### 8.3 压测触发扩容（3 → 5）
```bash
# 压测工具（master 或客户端）
yum install -y httpd-tools
ab -n 10000 -c 1000 http://web.ouyang.com:30710/

# 观察扩容
watch kubectl get hpa,pods
# CPU 超过 50% 后，副本自动从 3 扩到 5；压测停止约 5 分钟后缩回
```

> HPA 原理：metrics-server 采集 Pod CPU → HPA controller 按公式 `ceil(副本数 × 实际利用率 / 目标利用率)` 计算期望副本 → 写入 Deployment replicas。利用率分母是 requests 值，所以 Pod 必须设置 requests。

---

## 9. 滚动更新 / 回滚 / 故障自愈演练

### 9.1 滚动更新（v1 → v2，零中断）
```bash
kubectl set image deployment/webapp webapp=webapp:v2
kubectl rollout status deployment/webapp
kubectl get rs          # 新旧 ReplicaSet 并存，旧的保留
# 边更新边压测，观察连接不中断（maxSurge/maxUnavailable 默认 25%）
```

### 9.2 版本回滚
```bash
kubectl rollout history deployment/webapp
kubectl rollout undo deployment/webapp            # 回到上一版本
kubectl rollout undo deployment/webapp --to-revision=1   # 指定版本
```

### 9.3 故障自愈演练
```bash
# Pod 级：删除后 Deployment 自动重建
kubectl delete pod <webapp-pod>
kubectl get pods -w        # 自动拉起新 Pod

# 节点级：关机 node 节点，观察 Pod 被驱逐并在其他节点重建
# （NodeController 默认约 5 分钟判定节点失联并驱逐 Pod）
kubectl get nodes -w
kubectl get pods -o wide -w
```

---

## 10. 监控体系：Prometheus + Grafana

### 10.1 node-exporter（节点指标，DaemonSet 每节点一个）
```bash
kubectl apply -f node-exporter.yaml
kubectl get pods -n kube-system -o wide | grep node-exporter   # 3 个 Running
# 验证指标端口
curl http://192.168.194.130:9100/metrics | head
```
> **master 污点**：master 默认带 `node-role.kubernetes.io/master:NoSchedule` 污点，普通 Pod 不会调度上去。node-exporter 的 YAML 里加了 `tolerations` 容忍该污点，才能覆盖三台节点。

### 10.2 kube-state-metrics（集群对象状态）
```bash
kubectl apply -f kube-state-metrics.yaml
kubectl get pods -n kube-system | grep kube-state-metrics
```

### 10.3 Prometheus（master 节点）
1. 下载二进制并配置 systemd 服务：
```bash
wget https://github.com/prometheus/prometheus/releases/download/v2.45.0/prometheus-2.45.0.linux-amd64.tar.gz
tar xf prometheus-2.45.0.linux-amd64.tar.gz -C /opt
```
2. 编写抓取配置 `prometheus.yml`（见仓库，两个 job：k8s-nodes 抓三节点 9100、kube-state-metrics 抓对象指标）
3. 配置 systemd 服务并启动，验证 `http://192.168.194.130:9090/targets` 全部 UP

### 10.4 Grafana（master 节点）
```bash
# 下载慢时可用 rpm 包离线安装，或 docker 方式：
docker run -d --name grafana -p 3000:3000 grafana/grafana
```
1. 登录 `http://192.168.194.130:3000`（默认 admin/admin，首次强制改密）
2. 添加数据源：Prometheus，URL `http://192.168.194.130:9090`
3. 导入仪表盘 **1860**（Node Exporter Full），选择数据源 Prometheus

### 10.5 验证监控
- Grafana 三节点主机面板显示 CPU/内存/磁盘/网络
- 停掉一个 node 的 kubelet，观察 Prometheus target 变 DOWN、Grafana 告警触发

---

## 11. 项目成果

- 3 节点 K8s 集群（kubeadm + Calico），Pod 网络互通
- Web 应用容器化编排，Ingress 域名对外发布（web.ouyang.com:30710）
- 滚动更新/回滚零中断；HPA 压测 3→5 自动扩容
- 节点宕机 Pod 自动驱逐重建，业务自愈
- Prometheus + Grafana 全链路监控（节点 + 集群对象）
