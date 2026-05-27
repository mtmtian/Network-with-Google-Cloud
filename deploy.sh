#!/usr/bin/env bash
# One-command deploy: provision GCP VM + install proxy server + generate Clash configs.
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$KIT_DIR/lib/common.sh"

printf '\n\033[1;35m=== GCP 代理一键部署 ===\033[0m\n\n'

# ── 0. 预检 ──
bash "$KIT_DIR/lib/preflight.sh"

# ── 1. 配置 ──
if [ ! -f "$CONF_FILE" ]; then
  say "首次运行，开始交互式配置"
  default_proj="$(gcloud config get-value project 2>/dev/null || true)"
  printf '  GCP 项目 ID [%s]: ' "${default_proj:-请输入}"
  read -r in_proj
  proj="${in_proj:-$default_proj}"
  [ -n "$proj" ] || die "必须提供项目 ID"
  printf '  区域 REGION [us-west1]: '; read -r in_region
  region="${in_region:-us-west1}"
  printf '  可用区 ZONE [%s-a]: ' "$region"; read -r in_zone
  zone="${in_zone:-${region}-a}"
  printf '  设备列表 [mac iphone ipad laptop spare]: '; read -r in_dev
  devs="${in_dev:-mac iphone ipad laptop spare}"

  sed -e "s|^PROJECT_ID=.*|PROJECT_ID=${proj}|" \
      -e "s|^REGION=.*|REGION=${region}|" \
      -e "s|^ZONE=.*|ZONE=${zone}|" \
      -e "s|^DEVICES=.*|DEVICES=\"${devs}\"|" \
      "$KIT_DIR/deploy.conf.example" > "$CONF_FILE"
  ok "已写入 deploy.conf（可手动编辑后重跑）"
fi
load_conf
ok "项目=$PROJECT_ID  区域=$REGION  设备=[$DEVICES]"

# ── 2. 密钥 ──
bash "$KIT_DIR/lib/secrets.sh"
load_secrets

# ── 3. 开云资源 ──
bash "$KIT_DIR/lib/provision.sh"
load_secrets

# ── 4. 安装服务端，回收 Reality 公钥 ──
say "推送并执行服务端安装脚本（首次约 1-2 分钟）"
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
srv_env="$tmpd/server-env.sh"
{
  for k in REALITY_PORT REALITY_SNI DEVICES; do
    printf "export %s='%s'\n" "$k" "$(varval "$k")"
  done
  for k in REALITY_SHORTID HY2_PORT ANYTLS_PORT ANYTLS_PASS; do
    printf "export %s='%s'\n" "$k" "$(secret_get "$k")"
  done
  for d in $DEVICES; do
    printf "export REALITY_UUID_%s='%s'\n" "$d" "$(secret_get "REALITY_UUID_$d")"
    printf "export HY2_PASS_%s='%s'\n" "$d" "$(secret_get "HY2_PASS_$d")"
  done
} > "$srv_env"

GC=(gcloud --project "$PROJECT_ID" --quiet)
scp_ok=0
for attempt in 1 2 3; do
  if "${GC[@]}" compute scp --tunnel-through-iap --zone "$ZONE" \
       "$KIT_DIR/setup-server.sh" "$srv_env" "$INSTANCE_NAME":/tmp/ 2>/dev/null; then
    scp_ok=1; break
  fi
  warn "SSH 尚未就绪，等待重试 ($attempt/3)..."; sleep 15
done
[ "$scp_ok" -eq 1 ] || die "无法通过 IAP SSH 连接到 VM，请稍后重跑 ./deploy.sh"

srv_out="$("${GC[@]}" compute ssh --tunnel-through-iap --zone "$ZONE" \
  "$INSTANCE_NAME" --command "bash /tmp/setup-server.sh /tmp/server-env.sh" 2>&1 || true)"
echo "$srv_out" | sed 's/^/    │ /'

pub="$(echo "$srv_out" | grep '^REALITY_PUBLIC_KEY=' | tail -1 | cut -d= -f2)"
[ -n "$pub" ] || die "未能从服务器取回 Reality 公钥，安装可能失败（见上方日志）"
setkv REALITY_PUBLIC "$pub"
ok "Reality 公钥已回收"

# ── 5. 生成 Clash 配置 ──
say "生成 Clash 配置"
python3 "$KIT_DIR/gen-clash.py"

# ── 6. 收尾 ──
load_secrets
printf '\n\033[1;32m=== 部署完成 ===\033[0m\n'
echo "  服务器 IP : $STATIC_IP"
echo "  Reality   : 端口 $REALITY_PORT  SNI $REALITY_SNI"
echo "  Hysteria2 : 端口 $HY2_PORT (UDP)"
echo "  AnyTLS    : 端口 $ANYTLS_PORT (TCP)"
echo "  配置文件  : $KIT_DIR/clash-configs/*.yaml"
echo ""
echo "导入 Clash Verge：设置 → 配置 → 导入 → 选择 clash-configs/ 下对应设备的 .yaml"
echo "手机端请使用支持 Reality / Hysteria2 / AnyTLS 的 Mihomo / Clash.Meta 兼容客户端，再导入对应 yaml"
