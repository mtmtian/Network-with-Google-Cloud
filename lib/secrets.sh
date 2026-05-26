#!/usr/bin/env bash
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT_DIR/lib/common.sh"
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

# SS 端口：deploy.conf 已指定则沿用，否则随机高位端口（落入 .secrets.env）
if [ -z "${SS_PORT:-}" ]; then
  if command -v shuf >/dev/null 2>&1; then
    port="$(shuf -i 40000-65000 -n1)"
  else
    port="$(python3 -c 'import random; print(random.randint(40000,65000))')"
  fi
  ensure_secret SS_PORT "$port"
fi

# Hysteria2 端口：UDP，随机高位（独立于 SS 端口范围，避免冲突）
if [ -z "${HY2_PORT:-}" ]; then
  if command -v shuf >/dev/null 2>&1; then
    hy2p="$(shuf -i 30000-39999 -n1)"
  else
    hy2p="$(python3 -c 'import random; print(random.randint(30000,39999))')"
  fi
  ensure_secret HY2_PORT "$hy2p"
fi

# 服务器主密钥(iPSK) + Reality short-id（全设备共用）
ensure_secret SS_IPSK        "$(rand_psk)"
ensure_secret REALITY_SHORTID "$(rand_short)"

# 每设备独立 uPSK / Reality UUID / Hysteria2 密码（可单独作废）
for d in ${DEVICES:-mac iphone ipad laptop spare}; do
  ensure_secret "SS_UPSK_$d"      "$(rand_psk)"
  ensure_secret "REALITY_UUID_$d" "$(gen_uuid)"
  ensure_secret "HY2_PASS_$d"     "$(rand_psk)"
done

ok "密钥就绪（已写入 .secrets.env）"
