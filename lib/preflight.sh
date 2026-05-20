#!/usr/bin/env bash
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT_DIR/lib/common.sh"

say "预检环境依赖..."

missing=0

need() {  # need CMD HINT
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 已安装"
  else
    warn "缺少 $1 — $2"
    missing=1
  fi
}

need gcloud   "安装方式见 https://cloud.google.com/sdk/docs/install"
need python3  "macOS: brew install python3 ；Debian/Ubuntu: sudo apt install python3"
need openssl  "通常系统自带；缺失请用包管理器安装"

# uuid 来源：uuidgen 或 python3 均可
if command -v uuidgen >/dev/null 2>&1; then
  ok "uuidgen 已安装"
else
  warn "缺少 uuidgen（将回退到 python3 生成 UUID）"
fi

[ "$missing" -eq 0 ] || die "请先安装上述缺失的依赖，再重新运行 ./deploy.sh"

# gcloud 登录态
if gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
  ok "gcloud 已登录：$acct"
else
  die "gcloud 未登录。请先运行：gcloud auth login"
fi

ok "预检通过"
