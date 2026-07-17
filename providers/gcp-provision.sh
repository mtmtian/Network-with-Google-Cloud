#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$PROJECT_DIR/core/common.sh"
load_conf
load_secrets

: "${PROJECT_ID:?deploy.conf 缺少 PROJECT_ID}"
: "${REGION:?}" "${ZONE:?}" "${INSTANCE_NAME:?}" "${IP_NAME:?}"
: "${MACHINE_TYPE:=e2-micro}" "${NETWORK_TIER:=PREMIUM}"
: "${REALITY_PORT:=443}"
: "${HY2_PORT:?HY2_PORT 未生成，请先运行 secrets.sh}"
: "${ANYTLS_PORT:?ANYTLS_PORT 未生成，请先运行 secrets.sh}"
HY2_FIREWALL_PORT="${HY2_PORT_RANGE:-$HY2_PORT}"

GC=(gcloud --project "$PROJECT_ID" --quiet)

gcloud_retry() {
  local attempt status delay
  delay=3
  for attempt in 1 2 3; do
    if "${GC[@]}" "$@"; then
      return 0
    else
      status=$?
    fi
    if [ "$attempt" -lt 3 ]; then
      warn "gcloud 请求失败，${delay}s 后重试 (${attempt}/3)..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  return "$status"
}

say "[1/4] 启用 Compute Engine API（幂等）"
gcloud_retry services enable compute.googleapis.com

say "[2/4] 预留静态外部 IP：${IP_NAME}（${REGION} / ${NETWORK_TIER}）"
if gcloud_retry compute addresses describe "$IP_NAME" --region "$REGION" >/dev/null 2>&1; then
  ok "IP 已存在，复用"
else
  gcloud_retry compute addresses create "$IP_NAME" --region "$REGION" --network-tier "$NETWORK_TIER"
fi
STATIC_IP="$(gcloud_retry compute addresses describe "$IP_NAME" --region "$REGION" --format='value(address)')"
setkv STATIC_IP "$STATIC_IP"
ok "静态 IP：$STATIC_IP"

say "[3/4] 防火墙规则（幂等）"
FW_RULES="tcp:${REALITY_PORT},udp:${HY2_FIREWALL_PORT},tcp:${ANYTLS_PORT}"
if gcloud_retry compute firewall-rules describe allow-proxy >/dev/null 2>&1; then
  gcloud_retry compute firewall-rules update allow-proxy \
    --rules "$FW_RULES"
else
  gcloud_retry compute firewall-rules create allow-proxy \
    --network default --direction INGRESS --action ALLOW \
    --rules "$FW_RULES" \
    --source-ranges 0.0.0.0/0 --target-tags vpn-node
fi

CDN_ONLY_BLOCK_RULE="network-node-cdn-only-block"
if [ "${CDN_ONLY:-false}" = "true" ]; then
  if gcloud_retry compute firewall-rules describe "$CDN_ONLY_BLOCK_RULE" >/dev/null 2>&1; then
    gcloud_retry compute firewall-rules update "$CDN_ONLY_BLOCK_RULE" --no-disabled
  else
    gcloud_retry compute firewall-rules create "$CDN_ONLY_BLOCK_RULE" \
      --network default --direction INGRESS --action DENY \
      --rules "$FW_RULES" --priority 900 \
      --source-ranges 0.0.0.0/0 --target-tags vpn-node
  fi
else
  if gcloud_retry compute firewall-rules describe "$CDN_ONLY_BLOCK_RULE" >/dev/null 2>&1; then
    gcloud_retry compute firewall-rules update "$CDN_ONLY_BLOCK_RULE" --disabled
  fi
fi
if ! gcloud_retry compute firewall-rules describe allow-iap-ssh >/dev/null 2>&1; then
  gcloud_retry compute firewall-rules create allow-iap-ssh \
    --network default --direction INGRESS --action ALLOW \
    --rules tcp:22 --source-ranges 35.235.240.0/20
fi
ok "防火墙就绪（代理端口对公网、SSH 仅 IAP）"

say "[4/4] 创建 VM：${INSTANCE_NAME}（${MACHINE_TYPE} / Debian 12 / ${ZONE}）"
if gcloud_retry compute instances describe "$INSTANCE_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  ok "VM 已存在，跳过创建"
else
  gcloud_retry compute instances create "$INSTANCE_NAME" \
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
