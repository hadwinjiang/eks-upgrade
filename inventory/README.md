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
执行期间屏幕上会打印 `[01]..[47]` 的进度，不是卡住。

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

**目录内容**：集群配置与版本信息 —— 节点版本、Calico 配置、**节点组与启动模板全量配置**、
StorageClass、工作负载副本数与调度约束、NetworkPolicy 数量、addon 版本。
**不含** Secret、不含业务数据、不含 Pod 内容、不含镜像内容。

### ⚠️ 关于 UserData（回传前请过一眼）

为了能设计出"配置一致"的新节点组，脚本会把启动模板的 **UserData base64 解码后原文收录**。
正常内容是 `bootstrap.sh` 的参数（集群名、apiserver endpoint、集群 CA 证书、
`--kubelet-extra-args` 里的 labels/taints）—— 这些都不是机密，但**如果你们在 UserData 里
写了自定义开机逻辑**（内网地址、token、私有仓库凭证等），它会一并出现在回传文件里。

两个选择：

```bash
./01-inventory.sh --all --no-userdata    # 完全不采 UserData
```
或者照常采集，回传前检查这一节：

```bash
grep -A40 '启动模板 UserData' inventory-*/
```

不采 UserData 的代价：新节点组的开机逻辑要另外人工提供，否则只能复刻标准 bootstrap 参数。

`MISSING.txt` 里有条目是正常的 —— 比如 `aws-node not found` 恰恰是"没装 vpc-cni"的证据。
不必为它补跑，回传时带上即可。

## 节点组与启动模板采了什么（设计新节点组用的）

这是设计新节点组最关键的一组，共 7 项：

| 采集项 | 内容 | 为什么需要 |
|---|---|---|
| 节点组完整配置 | `describe-nodegroup` **全量 JSON**，不裁字段 | scalingConfig / updateConfig / labels / taints / tags / subnets / remoteAccess / nodeRole 一个不漏 |
| 启动模板 | 版本号信息 + **全量 `LaunchTemplateData`**（节点组钉的版本 与 `$Latest` 都采） | 🔴 LT 型节点组的 `instanceTypes`/`diskSize` 在 `describe-nodegroup` 里是 **null**，真值在 LT 里：卷大小/类型/IOPS/吞吐/加密、SG、IMDS（`HttpTokens`/`HopLimit`）、ImageId |
| UserData | base64 解码后原文 | bootstrap 参数、`--kubelet-extra-args` 的 labels/taints、自定义开机逻辑 |
| ASG 配置 | 混合实例策略、`InstancesDistribution`（按需/Spot 比例）、终止策略、挂起的流程、生命周期钩子、预热池 | 这些**不在**节点组字段里，新组若要行为一致必须单独复刻 |
| 自管节点组检测 | 带本集群标签但不在托管 ASG 白名单里的 ASG | 🔴 自管组**不会**出现在 `list-nodegroups`。漏掉 ⇒ 升级方案阶段 B 整段不适用（托管用 `update-nodegroup-version`，自管要换 LT + 轮换 ASG） |
| 节点实机与根卷 | 每节点的机型/AMI/AZ + 每个卷的大小/类型/IOPS/吞吐/**是否加密**/KMS key | 实际跑着的配置可能与 LT 不一致（LT 改过但节点没轮换）；加密与 KMS key 新组要对齐 |
| AMI 详情 | AMI 名称/创建时间/**弃用时间**/架构 | 确认钉死的是哪个镜像、还有多久弃用 |

### 一个实测到的坑（直接影响新节点组设计）

同一个集群里两种建法的根卷默认值不同：

| 节点组 | 建法 | 根卷实测 |
|---|---|---|
| LT 型（`amiType=CUSTOM`） | 自定义 LT 的 `BlockDeviceMappings` | **gp3 / 3000 IOPS / 125 吞吐** |
| 托管 AMI 型 | `aws eks create-nodegroup --disk-size 30` | **gp2 / 100 IOPS**（EKS 默认 gp2！） |

⇒ 用 `--managed-ami` 把 LT 型克隆成托管型时，**根卷会从 gp3 悄悄退回 gp2**。
若要保持 gp3，新节点组仍得带一个只含 `BlockDeviceMappings` 的 LT。
这一条请在看完采集结果后逐个节点组确认。

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
