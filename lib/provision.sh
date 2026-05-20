#!/usr/bin/env bash
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT_DIR/lib/common.sh"
load_conf
load_secrets

: "${PROJECT_ID:?deploy.conf 缺少 PROJECT_ID}"
: "${REGION:?}" "${ZONE:?}" "${INSTANCE_NAME:?}" "${IP_NAME:?}"
: "${MACHINE_TYPE:=e2-micro}" "${NETWORK_TIER:=PREMIUM}"
: "${REALITY_PORT:=443}" "${SS_PORT:?SS_PORT 未生成，请先运行 secrets.sh}"

GC=(gcloud --project "$PROJECT_ID" --quiet)

say "[1/4] 启用 Compute Engine API（幂等）"
"${GC[@]}" services enable compute.googleapis.com

say "[2/4] 预留静态外部 IP：$IP_NAME（$REGION / $NETWORK_TIER）"
if "${GC[@]}" compute addresses describe "$IP_NAME" --region "$REGION" >/dev/null 2>&1; then
  ok "IP 已存在，复用"
else
  "${GC[@]}" compute addresses create "$IP_NAME" --region "$REGION" --network-tier "$NETWORK_TIER"
fi
STATIC_IP="$("${GC[@]}" compute addresses describe "$IP_NAME" --region "$REGION" --format='value(address)')"
setkv STATIC_IP "$STATIC_IP"
ok "静态 IP：$STATIC_IP"

say "[3/4] 防火墙规则（幂等）"
if "${GC[@]}" compute firewall-rules describe allow-proxy >/dev/null 2>&1; then
  "${GC[@]}" compute firewall-rules update allow-proxy \
    --rules "tcp:${SS_PORT},udp:${SS_PORT},tcp:${REALITY_PORT}"
else
  "${GC[@]}" compute firewall-rules create allow-proxy \
    --network default --direction INGRESS --action ALLOW \
    --rules "tcp:${SS_PORT},udp:${SS_PORT},tcp:${REALITY_PORT}" \
    --source-ranges 0.0.0.0/0 --target-tags vpn-node
fi
if ! "${GC[@]}" compute firewall-rules describe allow-iap-ssh >/dev/null 2>&1; then
  "${GC[@]}" compute firewall-rules create allow-iap-ssh \
    --network default --direction INGRESS --action ALLOW \
    --rules tcp:22 --source-ranges 35.235.240.0/20
fi
ok "防火墙就绪（代理端口对公网、SSH 仅 IAP）"

say "[4/4] 创建 VM：$INSTANCE_NAME（$MACHINE_TYPE / Debian 12 / $ZONE）"
if "${GC[@]}" compute instances describe "$INSTANCE_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  ok "VM 已存在，跳过创建"
else
  "${GC[@]}" compute instances create "$INSTANCE_NAME" \
    --zone "$ZONE" \
    --machine-type "$MACHINE_TYPE" \
    --image-family debian-12 --image-project debian-cloud \
    --boot-disk-size 30GB --boot-disk-type pd-standard \
    --address "$STATIC_IP" \
    --network-tier "$NETWORK_TIER" \
    --tags vpn-node
  ok "VM 已创建，等待 SSH 就绪..."
  sleep 20
fi

ok "云资源就绪"
