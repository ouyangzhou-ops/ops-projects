# K8s 云原生 Web 应用部署实践

基于 Kubernetes 搭建容器化 Web 业务平台，完成应用容器化、服务编排、流量接入与监控告警，模拟企业容器化业务上线流程。

## 环境

- 3 节点 Kubernetes 集群（1 master + 2 node），kubeadm 部署，版本 v1.23.17
- 操作系统：CentOS 7（VMware Workstation 虚拟机）
- 组件：Calico（网络）、ingress-nginx、metrics-server、Kubernetes Dashboard

## 访问链路

```
浏览器 http://web.ouyang.com:30710
  → hosts 解析 → master 192.168.194.130
  → ingress-nginx（NodePort 30710）
  → Ingress 规则（host: web.ouyang.com）
  → Service webapp-svc（ClusterIP:80）
  → Deployment webapp Pod（3 副本，HPA 可扩至 5）
```

## 实施步骤

1. **业务镜像制作**：Dockerfile 构建 nginx 业务镜像 webapp:v1/v2，分发至各节点
2. **Deployment 部署**：多副本部署 + 资源限制（requests/limits）+ 滚动更新 + 版本回滚
3. **Service**：ClusterIP 提供服务内部访问与负载均衡
4. **Ingress**：配置域名 web.ouyang.com 路由转发，对外暴露服务
5. **HPA 弹性伸缩**：CPU 超 50% 自动扩容（副本 1~5），压测验证副本 3→5
6. **故障自愈演练**：Pod 删除自动重建；节点宕机后业务约 5 分钟自动迁移恢复
7. **监控**：node-exporter（DaemonSet）+ kube-state-metrics，接入 Prometheus + Grafana（仪表盘 1860）

## 文件说明

| 文件 | 说明 |
|---|---|
| [webapp.yaml](webapp.yaml) | Deployment（3 副本 + 资源限制） |
| [svc.yaml](svc.yaml) | Service ClusterIP:80 |
| [ingress.yaml](ingress.yaml) | Ingress 域名路由（ingressClassName: nginx） |
| [hpa.yaml](hpa.yaml) | HPA（CPU 50%，1~5 副本） |
| [node-exporter.yaml](node-exporter.yaml) | 节点指标采集 DaemonSet（含 master 污点容忍） |
| [kube-state-metrics.yaml](kube-state-metrics.yaml) | 集群对象状态采集（含 RBAC） |
| [Dockerfile](Dockerfile) | 业务镜像构建 |

## 排障记录

### 1. 外部访问 404
- **现象**：web.ouyang.com:30710 能连通但返回 404
- **排查**：kubectl get ingress / describe ingress / kubectl get endpoints webapp-svc
- **根因**：Ingress 资源缺少 `ingressClassName: nginx`，ingress-nginx 不认该路由
- **解决**：重建 Ingress 并补充 ingressClassName

### 2. 浏览器拒绝连接
- **现象**：域名解析正常但端口连不上
- **根因**：ingress-nginx controller 的 Service 为 ClusterIP，外部流量无法进入
- **解决**：patch Service 为 NodePort，得到对外端口 30710

### 3. node-exporter 未调度到 master
- **现象**：DaemonSet 只有 2 个副本（master 缺失）
- **根因**：master 节点带污点 node-role.kubernetes.io/master:NoSchedule
- **解决**：YAML 添加 tolerations 容忍污点

### 4. kube-state-metrics 镜像拉取失败
- **现象**：Pod 处于 ImagePullBackOff
- **根因**：registry.k8s.io 镜像源不可达；备用源 bitnami 的 2.10.1 tag 不存在
- **解决**：更换为 docker.io/bitnami/kube-state-metrics:latest

## 项目成果

- 实现 Web 应用容器化编排与域名对外发布
- 滚动更新与版本回滚零中断，压测下副本自动由 3 扩容至 5
- 节点宕机后业务约 5 分钟自动迁移恢复
- 搭建 Prometheus + Grafana 全链路监控体系
