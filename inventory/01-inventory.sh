#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  01-inventory.sh —— 集群现状采集（**只读**）
#
#  目的：在排升级窗口之前，把每个集群的真实形态一次性采全，用来判断
#        「Calico v3.28.3 → v3.30.7 + 节点组 → 1.31 + 控制面 → 1.32」
#        这套方案对该集群是否适用、以及要填哪些参数。
#
#  🔒 只读保证：全脚本只用 kubectl get / describe / version / api-resources
#     和 aws ... describe|list 这类读操作，**没有任何 create/apply/patch/delete**。
#     不读取任何 Secret。可以放心在生产集群上执行。
#
#  用法：
#    ./01-inventory.sh                      # 只采当前 kubectl context
#    ./01-inventory.sh ctx-a ctx-b          # 采指定的若干 context
#    ./01-inventory.sh --all                # 采 kubeconfig 里的全部 context
#    ./01-inventory.sh --list               # 只列出可选 context，不采集
#
#  前提：
#    · kubectl 可用、且对目标集群有只读权限（经 Rancher 代理访问也可以）
#    · aws CLI **可选**：有就额外采 EKS 托管面信息（addon 版本/节点组/子网 IP），
#      没有就自动跳过，核心信息不受影响
#
#  耗时：每个集群约 3–5 分钟（40 项检查）。9 个集群请预留 40 分钟。
#        执行期间会在屏幕上打印 [01]..[40] 的进度。
#
#  产出：
#    inventory-<UTC日期>/<context>.txt   每集群一份明细
#    inventory-<UTC日期>/summary.tsv     9 个集群横向对比（制表符分隔，可直接贴表格）
#    inventory-<UTC日期>/MISSING.txt     采不到的项 + 原因（权限/命令不存在/对象不存在）
#
#  把整个 inventory-<日期>/ 目录打包回传即可。里面不含 Secret 与业务数据。
# ════════════════════════════════════════════════════════════════
set -uo pipefail

TS="$(date -u '+%Y%m%d')"
OUT="${OUT:-inventory-$TS}"
SUM="$OUT/summary.tsv"
MISS="$OUT/MISSING.txt"

# ── context 列表 ────────────────────────────────────────────────
case "${1:-}" in
  --list)
    echo "kubeconfig 里的 context："
    kubectl config get-contexts -o name 2>/dev/null || echo "  (读不到 kubeconfig)"
    exit 0 ;;
  --all)  CTXS="$(kubectl config get-contexts -o name 2>/dev/null)" ;;
  "")     CTXS="$(kubectl config current-context 2>/dev/null)" ;;
  *)      CTXS="$*" ;;
esac
[ -n "${CTXS// /}" ] || { echo "🔴 没有可采集的 context。先跑 ./01-inventory.sh --list 看看有哪些"; exit 1; }

mkdir -p "$OUT"
: > "$MISS"
HAS_AWS=0; command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1 && HAS_AWS=1
[ "$HAS_AWS" = 1 ] || echo "aws CLI 不可用或未配置凭证 ⇒ 跳过 EKS 托管面信息（addon/节点组/子网），不影响核心采集" >> "$MISS"

# summary 表头（顺序即「判定方案适用性」要看的顺序）
printf '%s\n' "cluster	k8s_server	nodes	kubelet_versions	os_images	containerd	vpc_cni	calico_ver	operator_img	helm_release	calico_crd_count	ippool(name/cidr/block/vxlan/nat)	bgp	dataplane	mtu	nodegroups	node_taints	storageclasses	csi_drivers	pvc_total/notbound	netpol(k8s/global)	pdb_maxunavail0	single_replica	bare_pods	access_mode	addons" > "$SUM"

# ── 小工具 ──────────────────────────────────────────────────────
KC=""   # 当前集群的 kubectl 包装会用到
kc()  { kubectl --context "$CTX" --request-timeout=30s "$@" 2>&1; }
# 跑一条只读命令并写进明细文件；失败不中断，只记进 MISSING
RUN_N=0
run() {
  local label="$1"; shift
  RUN_N=$((RUN_N+1))
  printf '  [%02d] %s\n' "$RUN_N" "$label" >&2      # 进度：让执行者看得见脚本在动
  printf '\n----- %s -----\n' "$label" >> "$F"
  local o rc
  o="$("$@" 2>&1)"; rc=$?
  if [ $rc -ne 0 ] || [ -z "${o// /}" ]; then
    printf '%s\n' "${o:-<空>}" >> "$F"
    printf '%s\t%s\t%s\n' "$CTX" "$label" "$(printf '%s' "${o:-<空>}" | head -1)" >> "$MISS"
  else
    printf '%s\n' "$o" >> "$F"
  fi
}
# 取单值（失败返回 ?），用于 summary
one() { local o; o="$("$@" 2>/dev/null | tr -d '\r' | head -1)"; printf '%s' "${o:-?}"; }
# 节点信息一次性取回来缓存，汇总时从缓存里 awk，不再对 API 发 5 次重复查询
NODEJSON=""
node_col() {  # 用法：node_col <jsonpath 片段>，对每个节点取一次
  kubectl --context "$CTX" --request-timeout=30s get nodes \
    -o jsonpath="{range .items[*]}${1}{\"\n\"}{end}" 2>/dev/null | sed '/^$/d' | sort -u | paste -sd, -
}
# 多值去重后用 , 连接
many() { local o; o="$("$@" 2>/dev/null | sed '/^$/d' | sort -u | paste -sd, -)"; printf '%s' "${o:-?}"; }

# ════════════════════════════════════════════════════════════════
for CTX in $CTXS; do
  SAFE="$(printf '%s' "$CTX" | tr '/:' '__')"
  F="$OUT/$SAFE.txt"
  : > "$F"
  echo "════════ 采集 $CTX ════════"
  {
    echo "context : $CTX"
    echo "采集时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
    echo "采集脚本: 01-inventory.sh（只读）"
  } >> "$F"

  # 连通性先探一次，不通就跳过，避免后面刷一屏超时
  if ! kubectl --context "$CTX" --request-timeout=20s version -o json >/dev/null 2>&1; then
    echo "  🔴 连不上，跳过"
    echo "连不上：$(kubectl --context "$CTX" --request-timeout=20s version 2>&1 | head -2)" >> "$F"
    printf '%s\t%s\t%s\n' "$CTX" "连通性" "无法连接" >> "$MISS"
    printf '%s\t连不上\n' "$CTX" >> "$SUM"
    continue
  fi

  # ── A. 版本与节点 ───────────────────────────────────────────
  run "kubectl version"            kubectl --context "$CTX" version
  run "节点总览"                   kubectl --context "$CTX" get nodes -o wide
  run "节点 taint / nodegroup 标签" kubectl --context "$CTX" get nodes \
      -o custom-columns='NODE:.metadata.name,NG:.metadata.labels.eks\.amazonaws\.com/nodegroup,CAPACITY:.metadata.labels.eks\.amazonaws\.com/capacityType,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TAINTS:.spec.taints[*].key,UNSCHED:.spec.unschedulable'
  run "节点 label 全量（判断自管/托管、业务分组）" kubectl --context "$CTX" get nodes --show-labels

  # ── B. CNI：vpc-cni 在不在、Calico 什么形态 ──────────────────
  run "vpc-cni DaemonSet（NotFound = 没装 vpc-cni，符合 Calico 方案前提）" \
      kubectl --context "$CTX" -n kube-system get ds aws-node
  run "amazon-vpc-cni ConfigMap（NotFound 同上）" \
      kubectl --context "$CTX" -n kube-system get cm amazon-vpc-cni
  run "Calico 相关 namespace" kubectl --context "$CTX" get ns calico-system tigera-operator calico-apiserver
  run "tigera-operator / calico-system 工作负载镜像" kubectl --context "$CTX" get pods -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
  run "tigerastatus" kubectl --context "$CTX" get tigerastatus
  run "Installation CR（封装/数据面/MTU/registry 的权威来源）" \
      kubectl --context "$CTX" get installation default -o yaml
  run "IPPool（🔴 IPPOOL_* 参数就取这里，写错=全网断连）" kubectl --context "$CTX" get ippools \
      -o custom-columns='NAME:.metadata.name,CIDR:.spec.cidr,BLOCK:.spec.blockSize,VXLAN:.spec.vxlanMode,IPIP:.spec.ipipMode,NAT:.spec.natOutgoing,NODESEL:.spec.nodeSelector,DISABLED:.spec.disabled'
  run "BGPConfiguration" kubectl --context "$CTX" get bgpconfiguration default -o yaml
  run "FelixConfiguration" kubectl --context "$CTX" get felixconfiguration default -o yaml
  # ⚠️ 口径：这里数的是**集群里实际注册的** projectcalico|tigera CRD。
  #    与 chart 包内 crds/ 的文件数（v3.30.7 = 32）不是同一个数，实测 v3.30.7 集群是 30。
  #    判定用途：22 左右 ⇒ v3.28 系；30 左右 ⇒ v3.30 系。
  run "Calico/Tigera CRD 清单（v3.28 系约 22 类；v3.30 系约 30 类）" \
      kubectl --context "$CTX" get crd -o name
  run "Helm release（方案假设 release 名为 calico、ns 为 tigera-operator）" helm --kube-context "$CTX" list -A

  # ── C. 业务负载：第 3 步迁移的三道门禁就看这些 ───────────────
  run "全集群 Pod（按 ns 汇总）" kubectl --context "$CTX" get pods -A -o wide
  run "Deployment/StatefulSet/DaemonSet 副本数" kubectl --context "$CTX" get deploy,statefulset,daemonset -A
  run "单副本工作负载（迁移/滚动重启期间会中断）" kubectl --context "$CTX" get deploy,statefulset -A \
      -o jsonpath='{range .items[?(@.spec.replicas<2)]}{.kind}{" "}{.metadata.namespace}{"/"}{.metadata.name}{" replicas="}{.spec.replicas}{"\n"}{end}'
  run "PodDisruptionBudget（maxUnavailable=0 会把驱逐卡死）" kubectl --context "$CTX" get pdb -A \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,MIN:.spec.minAvailable,MAXUN:.spec.maxUnavailable,ALLOWED:.status.disruptionsAllowed'
  run "裸 Pod（无控制器，重启即消失）" kubectl --context "$CTX" get pods -A \
      -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{" "}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}'
  run "🔴 nodeSelector/亲和性是否钉在节点组名上（钉了就迁不走，必须先改 yaml）" \
      kubectl --context "$CTX" get deploy,statefulset -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" sel="}{.spec.template.spec.nodeSelector}{" aff="}{.spec.template.spec.affinity.nodeAffinity}{"\n"}{end}'
  run "容忍一切污点的工作负载（cordon/drain 挡不住它们）" \
      kubectl --context "$CTX" get deploy,statefulset,daemonset -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.template.spec.tolerations}{"\n"}{end}'

  # ── D. 存储 ────────────────────────────────────────────────
  run "StorageClass（1.31 已移除 in-tree gp2 provisioner，必须有 CSI 的 gp3/gp2）" \
      kubectl --context "$CTX" get sc -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class'
  run "PVC 状态" kubectl --context "$CTX" get pvc -A
  run "CSIDriver（ebs / efs 哪个在用）" kubectl --context "$CTX" get csidriver
  run "CSI 相关 DaemonSet/Deployment" kubectl --context "$CTX" get ds,deploy -n kube-system

  # ── E. 网络策略（升级前后要逐条核对）────────────────────────
  run "k8s NetworkPolicy" kubectl --context "$CTX" get networkpolicy -A
  run "Calico GlobalNetworkPolicy" kubectl --context "$CTX" get globalnetworkpolicies.crd.projectcalico.org
  run "Calico NetworkPolicy（projectcalico）" kubectl --context "$CTX" get networkpolicies.crd.projectcalico.org -A

  # ── F. 其它可能影响升级的组件 ───────────────────────────────
  run "kube-system 全部工作负载（找监控/安全 agent）" kubectl --context "$CTX" get deploy,ds,sts -n kube-system
  run "APIService（聚合层，控制面升级会重启它们）" kubectl --context "$CTX" get apiservice
  run "Webhook（升级期间失效会阻塞所有写操作）" kubectl --context "$CTX" get validatingwebhookconfiguration,mutatingwebhookconfiguration
  run "已弃用 API 用量线索：api-resources" kubectl --context "$CTX" api-resources --verbs=list -o name

  # ── G. EKS 托管面（需要 aws CLI）─────────────────────────────
  EKSNAME=""; EKSREGION=""
  if [ "$HAS_AWS" = 1 ]; then
    # 从 context 名里猜集群名；Rancher 代理的 context 名可能不含集群名，所以也让用户用 EKS_NAME= 覆盖
    EKSNAME="${EKS_NAME:-}"
    [ -z "$EKSNAME" ] && EKSNAME="$(printf '%s' "$CTX" | sed -E 's#^.*/##; s#^ctx-##')"
    # region：环境变量 > 从 EKS ARN 形式的 context 名里解析 > aws configure 默认值
    # 🔴 不能省：漏了 region，describe-cluster 会在默认 region 里找，报 ResourceNotFoundException（踩过）
    # region 推导优先级：**从被采集集群自己的 server URL 解析** 最权威，放第一位。
    # 🔴 不要让 AWS_REGION 排第一：它常是 shell profile 里的本机默认值，与集群实际 region 不一致
    #    （实测踩过：profile 是 us-west-2、集群在 eu-central-1 ⇒ ResourceNotFoundException）
    # ① EKS endpoint 形如 xxx.<sk1|gr7|...>.<region>.eks.amazonaws.com
    EKSREGION="$(kubectl --context "$CTX" --request-timeout=20s config view --minify \
      -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
      | sed -nE 's#^https://[^.]+\.[^.]+\.([a-z0-9-]+)\.eks\.amazonaws\.com.*#\1#p')"
    # ② context 名本身就是 EKS ARN
    [ -z "$EKSREGION" ] && EKSREGION="$(printf '%s' "$CTX" | sed -nE 's#^arn:aws:eks:([a-z0-9-]+):.*#\1#p')"
    # ③ 显式环境变量（经 Rancher 代理时 server URL 不含 region，就靠这个）
    [ -z "$EKSREGION" ] && EKSREGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    # ④ 兜底：本机默认值（最可能不对，所以脚本一定会把推导结果打出来让人核）
    [ -z "$EKSREGION" ] && EKSREGION="$(aws configure get region 2>/dev/null)"
    if [ -z "$EKSREGION" ]; then
      echo "aws CLI 可用但推不出 region ⇒ 跳过 EKS 托管面。请加 AWS_REGION=<region> 重跑" >> "$MISS"
      printf '  !! 推不出 region，跳过 EKS 托管面（加 AWS_REGION=<region> 重跑）\n' >&2
      HAS_AWS_THIS=0
    else
      HAS_AWS_THIS=1
      printf '  .. EKS 集群名=%s region=%s（不符请加 EKS_NAME= / AWS_REGION= 重跑）\n' "$EKSNAME" "$EKSREGION" >&2
    fi
  else
    HAS_AWS_THIS=0
  fi
  if [ "${HAS_AWS_THIS:-0}" = 1 ]; then
    run "EKS 集群（若集群名猜错会 NotFound，可用 EKS_NAME=<名> 重跑本集群）" \
        aws eks describe-cluster --region "$EKSREGION" --name "$EKSNAME" \
        --query 'cluster.{version:version,platformVersion:platformVersion,status:status,accessConfig:accessConfig,endpointPublic:resourcesVpcConfig.endpointPublicAccess,subnets:resourcesVpcConfig.subnetIds,sg:resourcesVpcConfig.clusterSecurityGroupId}'
    run "EKS addon 列表与版本" sh -c "for a in \$(aws eks list-addons --region '$EKSREGION' --cluster-name '$EKSNAME' --query addons --output text 2>/dev/null); do aws eks describe-addon --region '$EKSREGION' --cluster-name '$EKSNAME' --addon-name \$a --query 'addon.[addonName,addonVersion,status,serviceAccountRoleArn]' --output text; done"
    run "EKS 节点组（🔴 托管 vs 自管、amiType=CUSTOM 决定第 1 步要不要 --managed-ami）" \
        sh -c "for n in \$(aws eks list-nodegroups --region '$EKSREGION' --cluster-name '$EKSNAME' --query nodegroups --output text 2>/dev/null); do aws eks describe-nodegroup --region '$EKSREGION' --cluster-name '$EKSNAME' --nodegroup-name \$n --query 'nodegroup.[nodegroupName,version,releaseVersion,amiType,capacityType,instanceTypes[0],diskSize,scalingConfig.desiredSize,updateConfig.maxUnavailable,status,launchTemplate.id,nodeRole]' --output text; done"
    run "EKS 节点组的子网与标签/污点" \
        sh -c "for n in \$(aws eks list-nodegroups --region '$EKSREGION' --cluster-name '$EKSNAME' --query nodegroups --output text 2>/dev/null); do echo \"== \$n\"; aws eks describe-nodegroup --region '$EKSREGION' --cluster-name '$EKSNAME' --nodegroup-name \$n --query 'nodegroup.{subnets:subnets,labels:labels,taints:taints,tags:tags}'; done"
    run "EKS 升级前置检查 insights" aws eks list-insights --region "$EKSREGION" --cluster-name "$EKSNAME" \
        --query 'insights[].{name:name,status:insightStatus.status,cat:category}' --output table
    run "子网空闲 IP（控制面升级与新建节点组都要占 IP）" \
        sh -c "for s in \$(aws eks describe-cluster --region '$EKSREGION' --name '$EKSNAME' --query 'cluster.resourcesVpcConfig.subnetIds' --output text 2>/dev/null); do aws ec2 describe-subnets --region '$EKSREGION' --subnet-ids \$s --query 'Subnets[0].[SubnetId,AvailabilityZone,CidrBlock,AvailableIpAddressCount]' --output text; done"
    run "aws-auth（访问模式为 CONFIG_MAP 时才有）" kubectl --context "$CTX" -n kube-system get cm aws-auth -o yaml
  fi

  # ── H. 汇总一行 ─────────────────────────────────────────────
  SRV=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s version -o json 2>/dev/null | tr -d ' \"' | grep -oE 'gitVersion:v[0-9.]+' | tail -1 | cut -d: -f2")
  [ "$SRV" = "?" ] && SRV=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s version 2>/dev/null | grep -i server | grep -oE 'v[0-9]+\.[0-9]+\.[0-9-]+[a-z0-9]*'")
  NODES=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get nodes --no-headers 2>/dev/null | grep -c .")
  KUBELETS=$(node_col '{.status.nodeInfo.kubeletVersion}')
  OSIMG=$(node_col '{.status.nodeInfo.osImage}')
  CRUN=$(node_col '{.status.nodeInfo.containerRuntimeVersion}')
  VPCCNI=$(kubectl --context "$CTX" -n kube-system get ds aws-node >/dev/null 2>&1 && echo "有(不符合方案前提)" || echo "无")
  CALVER=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get installation default -o jsonpath='{.status.calicoVersion}' 2>/dev/null")
  OPIMG=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s -n tigera-operator get deploy tigera-operator -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null")
  HELMREL=$(one sh -c "helm --kube-context '$CTX' list -A 2>/dev/null | awk 'NR>1 && (\$2==\"tigera-operator\" || \$1==\"calico\"){print \$1\"@\"\$2\"/\"\$9}'")
  CRDN=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get crd -o name 2>/dev/null | grep -cE 'projectcalico|tigera'")
  IPP=$(many sh -c "kubectl --context '$CTX' --request-timeout=30s get ippools -o jsonpath='{range .items[*]}{.metadata.name}/{.spec.cidr}/{.spec.blockSize}/{.spec.vxlanMode}/{.spec.natOutgoing}{\"\n\"}{end}' 2>/dev/null")
  BGP=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get bgpconfiguration default -o jsonpath='{.spec.nodeToNodeMeshEnabled}' 2>/dev/null")
  # 没有 default BGPConfiguration 对 VXLAN 部署是正常的（BGP 未启用），别显示成 ? 让人误判
  [ "$BGP" = "?" ] && { kubectl --context "$CTX" --request-timeout=20s get bgpconfiguration default >/dev/null 2>&1 || BGP="无default(VXLAN部署正常)"; }
  DPLANE=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}' 2>/dev/null")
  MTU=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get installation default -o jsonpath='{.status.mtu}' 2>/dev/null")
  NGS=$(node_col '{.metadata.labels.eks\.amazonaws\.com/nodegroup}')
  TAINTS=$(node_col '{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}')
  SCS=$(many sh -c "kubectl --context '$CTX' --request-timeout=30s get sc --no-headers 2>/dev/null | awk '{print \$1\"(\"\$2\")\"}'")
  CSID=$(many sh -c "kubectl --context '$CTX' --request-timeout=30s get csidriver --no-headers 2>/dev/null | awk '{print \$1}'")
  PVCT=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get pvc -A --no-headers 2>/dev/null | grep -c .")
  PVCB=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get pvc -A --no-headers 2>/dev/null | awk '\$3!=\"Bound\"' | grep -c .")
  NPK=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get networkpolicy -A --no-headers 2>/dev/null | grep -c .")
  NPG=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get globalnetworkpolicies.crd.projectcalico.org --no-headers 2>/dev/null | grep -c .")
  PDB0=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get pdb -A -o jsonpath='{range .items[*]}{.spec.maxUnavailable}{\"\n\"}{end}' 2>/dev/null | grep -cx 0")
  SINGLE=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get deploy,statefulset -A -o jsonpath='{range .items[?(@.spec.replicas<2)]}x{\"\n\"}{end}' 2>/dev/null | grep -c x")
  BARE=$(one sh -c "kubectl --context '$CTX' --request-timeout=30s get pods -A -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{\"\n\"}{end}' 2>/dev/null | grep -cx ''")
  ACCESS="?"; ADDONS="?"
  if [ "${HAS_AWS_THIS:-0}" = 1 ]; then
    ACCESS=$(one aws eks describe-cluster --region "$EKSREGION" --name "$EKSNAME" --query 'cluster.accessConfig.authenticationMode' --output text)
    # ⚠️ 不要在双引号里用 --query 'join(`=`,...)'：反引号会被 shell 当成命令替换执行（踩过，结果恒为空）
    ADDONS=$(aws eks list-addons --region "$EKSREGION" --cluster-name "$EKSNAME" --query addons --output text 2>/dev/null \
      | tr '\t' '\n' | sed '/^$/d' | while read -r a; do
          v=$(aws eks describe-addon --region "$EKSREGION" --cluster-name "$EKSNAME" --addon-name "$a" \
                --query addon.addonVersion --output text 2>/dev/null)
          printf '%s=%s\n' "$a" "${v:-?}"
        done | paste -sd, -)
    [ -z "$ADDONS" ] && ADDONS="?"
  fi

  printf '%s\n' "$CTX	$SRV	$NODES	$KUBELETS	$OSIMG	$CRUN	$VPCCNI	$CALVER	$OPIMG	$HELMREL	$CRDN	$IPP	$BGP	$DPLANE	$MTU	$NGS	$TAINTS	$SCS	$CSID	$PVCT/$PVCB	$NPK/$NPG	$PDB0	$SINGLE	$BARE	$ACCESS	$ADDONS" >> "$SUM"
  echo "  → $F"
done

# ════════════════════════════════════════════════════════════════
echo
echo "════════ 完成 ════════"
echo "明细  : $OUT/<context>.txt"
echo "对比表: $SUM"
echo "缺失项: ${MISS}（$(grep -c . "$MISS" 2>/dev/null || echo 0) 条）"
echo
echo "请把整个 $OUT/ 目录打包回传："
echo "  tar czf $OUT.tar.gz $OUT"
echo
echo "目录内不含 Secret、不含业务数据，只有集群配置与版本信息。"
