#!/usr/bin/env bash
# Generic Debian/Ubuntu VPS adapter for core/deploy.sh (DMIT, Bandwagon, etc.).
PROVIDER_TITLE="VPS 代理一键部署"
PROVIDER_DESCRIPTION="provider=VPS"

provider_init() {
  local profile_key="$SSH_DIR/id_rsa.pem"
  VPS_HOST="${VPS_HOST:-${1:-$(secret_get STATIC_IP)}}"
  [ -n "$VPS_HOST" ] || die "用法：./deploy-vps.sh <VPS_PUBLIC_IP>"
  VPS_BOOTSTRAP_USER="${VPS_BOOTSTRAP_USER:-root}"
  VPS_ADMIN_USER="${VPS_ADMIN_USER:-mt}"
  VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
  if [ -f "$profile_key" ]; then
    VPS_SSH_KEY="${VPS_SSH_KEY:-$profile_key}"
  else
    VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_ed25519}"
  fi
  VPS_SSH_OPTS=(-i "$VPS_SSH_KEY" -p "$VPS_SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
  VPS_SCP_OPTS=(-i "$VPS_SSH_KEY" -P "$VPS_SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
}

provider_preflight() {
  local cmd
  for cmd in ssh scp python3 openssl; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
  done
  [ -f "$VPS_SSH_KEY" ] || die "找不到 SSH 私钥：$VPS_SSH_KEY"
}

provider_configure() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [ ! -f "$CONF_FILE" ]; then
    cp "$CONFIG_TEMPLATE" "$CONF_FILE"
    sed -i.bak -e 's|^PROJECT_ID=.*|PROJECT_ID=vps|' "$CONF_FILE"
    rm -f "$CONF_FILE.bak"
    ok "已创建 profiles/$PROFILE_NAME/deploy.conf；可按需修改端口"
  fi
  load_conf
  PROVIDER_DESCRIPTION="provider=VPS  主机=$VPS_HOST"
}

provider_provision() {
  if ssh "${VPS_SSH_OPTS[@]}" "${VPS_ADMIN_USER}@${VPS_HOST}" \
    'sudo -n true && printf ready' 2>/dev/null | grep -q ready; then
    ok "复用已存在的管理员：$VPS_ADMIN_USER"
  else
    say "检查初始 SSH：${VPS_BOOTSTRAP_USER}@${VPS_HOST}:${VPS_SSH_PORT}"
    ssh "${VPS_SSH_OPTS[@]}" "${VPS_BOOTSTRAP_USER}@${VPS_HOST}" 'printf ready' | grep -q ready \
      || die "SSH 连接失败；确认实例、公钥和 IP"

    say "创建独立 sudo 管理员并复制公钥"
    ssh "${VPS_SSH_OPTS[@]}" "${VPS_BOOTSTRAP_USER}@${VPS_HOST}" \
      "ADMIN_USER='$VPS_ADMIN_USER' bash -s" <<'REMOTE_BOOTSTRAP'
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "bootstrap user must be root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo ufw
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$ADMIN_USER"
fi
usermod -aG sudo "$ADMIN_USER"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "/home/$ADMIN_USER/.ssh/authorized_keys"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "/etc/sudoers.d/90-$ADMIN_USER"
chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
REMOTE_BOOTSTRAP

    say "验证新管理员 SSH，确认后才会禁用 root 登录"
    ssh "${VPS_SSH_OPTS[@]}" "${VPS_ADMIN_USER}@${VPS_HOST}" 'sudo -n true && printf ready' | grep -q ready \
      || die "新管理员验证失败；已停止，root 登录仍保留"
  fi

  setkv STATIC_IP "$VPS_HOST"
  say "配置 VPS 防火墙"
  ssh "${VPS_SSH_OPTS[@]}" "${VPS_ADMIN_USER}@${VPS_HOST}" \
    "SSH_PORT='$VPS_SSH_PORT' REALITY_PORT='$REALITY_PORT' HY2_PORT='$HY2_PORT' HY2_PORT_RANGE='${HY2_PORT_RANGE:-}' ANYTLS_PORT='$ANYTLS_PORT' CDN_ONLY='${CDN_ONLY:-false}' bash -s" <<'REMOTE_FIREWALL'
set -euo pipefail
sudo ufw default deny incoming >/dev/null
sudo ufw default allow outgoing >/dev/null
sudo ufw allow "${SSH_PORT}/tcp" >/dev/null
if [ "${CDN_ONLY}" = "true" ]; then
  sudo ufw delete allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
  sudo ufw delete allow "${HY2_PORT_RANGE:-${HY2_PORT}}/udp" >/dev/null 2>&1 || true
  sudo ufw delete allow "${ANYTLS_PORT}/tcp" >/dev/null 2>&1 || true
else
  sudo ufw allow "${REALITY_PORT}/tcp" >/dev/null
  sudo ufw allow "${HY2_PORT_RANGE:-${HY2_PORT}}/udp" >/dev/null
  sudo ufw allow "${ANYTLS_PORT}/tcp" >/dev/null
fi
sudo ufw --force enable >/dev/null
REMOTE_FIREWALL
}

provider_install() {
  local setup_script="$1" download_script="$2" env_file="$3"
  scp "${VPS_SCP_OPTS[@]}" "$setup_script" "$download_script" "$env_file" "${VPS_ADMIN_USER}@${VPS_HOST}:/tmp/"
  ssh "${VPS_SSH_OPTS[@]}" "${VPS_ADMIN_USER}@${VPS_HOST}" \
    'sudo bash /tmp/setup-server.sh /tmp/server-env.sh; rc=$?; sudo rm -f /tmp/server-env.sh /tmp/setup-server.sh /tmp/download.sh; exit $rc'
}

provider_print_summary() {
  echo "  Provider  : Generic VPS"
  echo "  服务器 IP : $VPS_HOST"
  echo "  SSH 用户  : ${VPS_ADMIN_USER}（root 已禁用）"
}
