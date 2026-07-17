#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$PROJECT_DIR/core/common.sh"
load_conf
load_secrets

say "生成/复用本地密钥..."

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}
rand_psk()   { openssl rand -base64 16; }       # 16 字节 -> aes-128 主/用户密钥
rand_short() { openssl rand -hex 8; }            # Reality short-id

ensure_port() {
  local key="$1" min="$2" max="$3" current port
  current="$(varval "$key")"
  if [ -n "$current" ]; then
    setkv "$key" "$current"
    return
  fi

  current="$(secret_get "$key")"
  [ -n "$current" ] && return

  if command -v shuf >/dev/null 2>&1; then
    port="$(shuf -i "${min}-${max}" -n1)"
  else
    port="$(python3 -c "import random; print(random.randint($min,$max))")"
  fi
  setkv "$key" "$port"
}

# HY2/AnyTLS 端口：deploy.conf 已指定则沿用，否则随机高位端口（落入 .secrets.env）
ensure_port HY2_PORT 30000 39999
ensure_port ANYTLS_PORT 20000 29999

# Reality short-id 与 AnyTLS 共享密码
ensure_secret REALITY_SHORTID "$(rand_short)"
ensure_secret ANYTLS_PASS     "$(rand_psk)"

# 每设备独立 Reality UUID 与 Hysteria2 密码（可单独作废）
for d in ${DEVICES:-mac iphone}; do
  ensure_secret "REALITY_UUID_$d" "$(gen_uuid)"
  ensure_secret "HY2_PASS_$d"     "$(rand_psk)"
done

# ── Cloudflare CDN 套娃出口的密钥（仅 CDN_ENABLE=true 时）──
if [ "${CDN_ENABLE:-false}" = "true" ]; then
  # WS 路径：deploy.conf 指定则沿用，否则随机（不带前导斜杠，gen-clash 与服务端统一加）
  if [ -n "${CDN_WS_PATH:-}" ]; then
    setkv CDN_WS_PATH "${CDN_WS_PATH#/}"
  else
    ensure_secret CDN_WS_PATH "$(openssl rand -hex 12)"
  fi
  # 每设备独立 CDN UUID，与 Reality UUID 不同 -> 两条链路凭据隔离
  for d in ${DEVICES:-mac iphone}; do
    ensure_secret "CDN_UUID_$d" "$(gen_uuid)"
  done
  # CF_API_TOKEN 由用户提供（建隧道用），不自动生成；缺失则提示但不中断
  if [ -z "$(secret_get CF_API_TOKEN)" ]; then
    warn "CDN_ENABLE=true 但 .secrets.env 缺 CF_API_TOKEN。"
    warn "请把 Cloudflare API token（权限 Account>Cloudflare Tunnel:Edit + Zone>DNS:Edit）写入："
    warn "  echo 'CF_API_TOKEN=<your-token>' >> $SECRETS_FILE"
    warn "否则 core/cloudflare.sh 无法建隧道，CDN 出口会被跳过。"
  fi
fi

if [ "${HY2_OBFS_ENABLE:-false}" = "true" ]; then
  ensure_secret HY2_OBFS_PASSWORD "$(rand_psk)"
fi

if [ "${HY2_ACME_ENABLE:-false}" = "true" ] && [ -z "$(secret_get HY2_ACME_DNS_TOKEN)" ]; then
  warn "HY2_ACME_ENABLE=true 但缺 HY2_ACME_DNS_TOKEN；请把 Cloudflare DNS API token 写入 .secrets.env 后重跑"
fi

ok "密钥就绪（已写入 .secrets.env）"
