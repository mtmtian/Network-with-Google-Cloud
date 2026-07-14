#!/usr/bin/env bash
# Entry point: configure an already-provisioned Debian/Ubuntu VPS.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_PROFILE="${VPS_PROFILE:-}"
if [ -z "$VPS_PROFILE" ]; then
  printf '请显式设置 VPS_PROFILE，例如：VPS_PROFILE=frantech ./deploy-vps.sh <VPS_PUBLIC_IP>\n' >&2
  exit 2
fi
case "$VPS_PROFILE" in
  *[!A-Za-z0-9_-]*)
    printf 'VPS_PROFILE 只能包含字母、数字、下划线和连字符：%s\n' "$VPS_PROFILE" >&2
    exit 2
    ;;
esac
PROFILE_NAME="$VPS_PROFILE"
. "$PROJECT_DIR/core/common.sh"
. "$PROJECT_DIR/providers/vps.sh"
. "$PROJECT_DIR/core/deploy.sh"
run_deploy "$@"
