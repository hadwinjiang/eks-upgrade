# 集群现状采集说明（给执行人）

一个只读脚本，把每个集群的真实形态采全，用来判断
「Calico v3.28.3 → v3.30.7 + 节点组 → 1.31 + 控制面 → 1.32」这套升级方案
对该集群**是否适用**、以及要填哪些参数。

## 这个脚本会不会动集群？

**不会。** 全脚本只用这些读操作：

- `kubectl get` / `describe` / `version` / `config view` / `api-resources`
- `aws eks describe-*` / `list-*`、`aws ec2 describe-subnets`

没有任何 `create` / `apply` / `patch` / `delete` / `scale` / `cordon` / `drain`，
也**不读取任何 Secret**。可以在生产集群营业时间执行。

## 怎么跑

```bash
chmod +x 01-inventory.sh

./01-inventory.sh --list          # 先看 kubeconfig 里有哪些 context
./01-inventory.sh --all           # 采全部 context（推荐）
./01-inventory.sh ctx-a ctx-b     # 或只采指定的几个
```

耗时**每个集群约 3–5 分钟**（40 项检查）。9 个集群请预留 40 分钟。
执行期间屏幕上会打印 `[01]..[40]` 的进度，不是卡住。

## 环境要求

| 项 | 要求 |
|---|---|
| `kubectl` | 必需。对目标集群有只读权限即可。**经 Rancher 代理访问也可以** |
| `helm` | 可选。有则额外采 Helm release 名与 chart 版本（判断 Calico 是不是 Helm 装的） |
| `aws` CLI | 可选。有且配了凭证则额外采 EKS 托管面：addon 版本、节点组（托管/自管、amiType）、子网空闲 IP、insights。**没有也不影响核心采集** |

### 关于 region（只在用 aws CLI 时相关）

脚本按这个顺序自动推导，并把结果打印出来让你核：

1. 从该集群自己的 server URL 解析（EKS endpoint 形如 `xxx.gr7.<region>.eks.amazonaws.com`）
2. context 名本身是 EKS ARN 的话从 ARN 取
3. 环境变量 `AWS_REGION` / `AWS_DEFAULT_REGION`
4. 本机 `aws configure` 默认值

屏幕上会出现这一行，**请核对一眼**：

```
.. EKS 集群名=xxx region=eu-central-1（不符请加 EKS_NAME= / AWS_REGION= 重跑）
```

经 Rancher 代理时 server URL 里没有 region，也可能猜不出 EKS 集群名。这两种情况显式指定：

```bash
EKS_NAME=aws-eu-central-1-shuziyanfazhongtai-prod AWS_REGION=eu-central-1 \
  ./01-inventory.sh <该集群的 context>
```

## 产出与回传

```
inventory-<UTC日期>/
├── <context>.txt    每集群一份明细（40 节）
├── summary.tsv      横向对比表（制表符分隔，可直接粘进 Excel）
└── MISSING.txt       采不到的项 + 原因（权限不足 / 命令不存在 / 对象不存在）
```

打包回传：

```bash
tar czf inventory-<日期>.tar.gz inventory-<日期>
```

**目录内容**：只有集群配置与版本信息（节点版本、Calico 配置、节点组参数、StorageClass、
工作负载副本数与调度约束、NetworkPolicy 数量、addon 版本）。
**不含** Secret、不含业务数据、不含 Pod 内容、不含镜像内容。

`MISSING.txt` 里有条目是正常的 —— 比如 `aws-node not found` 恰恰是"没装 vpc-cni"的证据。
不必为它补跑，回传时带上即可。

## summary.tsv 的列怎么看

真正决定「方案能否直接用」的是前 14 列：

| 列 | 期望值（方案适用） | 不符的后果 |
|---|---|---|
| `vpc_cni` | `无` | 有 vpc-cni ⇒ CNI 形态不同，方案不适用 |
| `calico_ver` | `v3.28.3` | 低于 v3.28 ⇒ 跨 UID 边界，需单独规划；已是 v3.30+ ⇒ 无需本次升级 |
| `helm_release` | `calico@tigera-operator/...` | 非 Helm 安装（manifest）⇒ 升级脚本走不通 |
| `calico_crd_count` | 约 `22`（v3.28 系） | 约 30 ⇒ 已是 v3.30 系 |
| `ippool(...)` | 逐集群记下来 | **这是升级脚本的必填参数，填错 = 全网断连** |
| `dataplane` | `Iptables` | `BPF` ⇒ 数据面不同，需单独评估 |
| `os_images` | `Amazon Linux 2` | AL2023 ⇒ 控制面可超过 1.32，节点组路径不同 |
| `kubelet_versions` | 记下来 | 与控制面差 >3 个小版本 ⇒ 必须先升节点组才能升控制面 |
| `nodegroups` | 记下来（可多个） | 节点组数量决定批量迁移要填几个 |
| `node_taints` | 记下来 | 探针与新节点组要继承同样的污点 |
| `storageclasses` | 要有 CSI 的 gp3/gp2 | 只有 in-tree `kubernetes.io/aws-ebs` ⇒ 1.31 上 PVC 会永久 Pending |
| `pdb_maxunavail0` | `0` | 非 0 ⇒ 这些 PDB 会把节点迁移的驱逐卡死，须先调整 |
| `single_replica` | 记下来 | 这些服务在滚动重启期间会中断，需业务侧确认 |
| `bare_pods` | `0` | 非 0 ⇒ 无控制器的裸 Pod，迁移时会消失，须人工处理 |

## 已知的无害报错

| 报错 | 含义 |
|---|---|
| `daemonsets.apps "aws-node" not found` | ✅ 没装 vpc-cni，符合方案前提 |
| `configmaps "amazon-vpc-cni" not found` | ✅ 同上 |
| `bgpconfigurations... "default" not found` | ✅ 未启用 BGP，VXLAN 部署的正常状态 |
| `the server doesn't have a resource type ...` | 该 CRD 未安装（比如集群没装 Calico 的 tier/staged 策略） |
