#!/usr/bin/env bash
# Runs ON the GCP VM. Reads /tmp/server-env.sh for credentials, installs
# Xray (VLESS+Reality), Hysteria2, and AnyTLS, then prints
# REALITY_PUBLIC_KEY=<key> on stdout so the local deployer can pick it up.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/download.sh"

ENV_FILE="${1:-/tmp/server-env.sh}"
# shellcheck disable=SC1090
. "$ENV_FILE"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
HYSTERIA_VERSION="${HYSTERIA_VERSION:-app/v2.10.0}"
ANYTLS_VERSION="${ANYTLS_VERSION:-0.0.13}"
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.7.2}"
HY2_SNI="${HY2_SNI:-www.bing.com}"
HY2_MASQUERADE_URL="${HY2_MASQUERADE_URL:-https://www.bing.com}"
HY2_PORT_RANGE="${HY2_PORT_RANGE:-}"
HY2_HOP_INTERVAL="${HY2_HOP_INTERVAL:-}"
HY2_ACME_ENABLE="${HY2_ACME_ENABLE:-false}"
HY2_ACME_DNS_PROVIDER="${HY2_ACME_DNS_PROVIDER:-cloudflare}"
: "${REALITY_PORT:?}" "${REALITY_TARGET:?}" "${REALITY_SHORTID:?}" "${DEVICES:?}"
REALITY_SNI="${REALITY_SNI:-}"
: "${HY2_PORT:?}" "${ANYTLS_PORT:?}" "${ANYTLS_PASS:?}"

case "$REALITY_TARGET" in
  *:*) ;;
  *) echo "REALITY_TARGET 必须是 host:port" >&2; exit 1 ;;
esac
if [ "$HY2_ACME_ENABLE" = "true" ]; then
  : "${HY2_ACME_DOMAIN:?HY2_ACME_ENABLE=true 但缺 HY2_ACME_DOMAIN}"
  : "${HY2_ACME_EMAIL:?HY2_ACME_ENABLE=true 但缺 HY2_ACME_EMAIL}"
  : "${HY2_ACME_DNS_TOKEN:?HY2_ACME_ENABLE=true 但缺 HY2_ACME_DNS_TOKEN}"
  [ "$HY2_ACME_DNS_PROVIDER" = "cloudflare" ] || {
    echo "当前只实现 Hysteria2 Cloudflare DNS-01，HY2_ACME_DNS_PROVIDER 必须为 cloudflare" >&2
    exit 1
  }
  HY2_SNI="$HY2_ACME_DOMAIN"
fi

vv() { eval "printf '%s' \"\${$1:-}\""; }   # indirect var read

echo "=== [1/8] Enabling BBR + high-BDP TCP tuning ==="
# marker "v2" 让本块在已部署（已有旧 "# VPN tuning" 块）的机器上也能追加；
# sysctl 后写覆盖先写，重复的 bbr/fq 无害。跨太平洋 RTT ~150ms 下，默认 6MB 缓冲
# 撑不满带宽时延积，放大 rmem/wmem 才能让 BBR 填满管道（提升 Reality/AnyTLS 吞吐）。
if ! grep -q "# VPN tuning v2" /etc/sysctl.conf; then
  sudo tee -a /etc/sysctl.conf > /dev/null <<'SYSCTL'

# VPN tuning v2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=131072
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fastopen=3
SYSCTL
fi
sudo sysctl -p > /dev/null
sysctl net.ipv4.tcp_congestion_control

echo "=== [2/8] Installing prerequisites ==="
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip xz-utils openssl

ARCH="$(uname -m)"

echo "=== [3/8] Installing Xray ==="
case "$ARCH" in
  x86_64)  XRAY_ZIP="Xray-linux-64.zip" ;;
  aarch64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
download_file /tmp/xray.zip \
  "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ZIP}"
sudo unzip -oq /tmp/xray.zip -d /usr/local/bin xray
sudo chmod 0755 /usr/local/bin/xray
print_first_line /usr/local/bin/xray version

echo "=== [4/8] Installing Hysteria2 ==="
case "$ARCH" in
  x86_64)  HY2_BIN="hysteria-linux-amd64" ;;
  aarch64) HY2_BIN="hysteria-linux-arm64" ;;
esac
download_file /tmp/hysteria \
  "https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/${HY2_BIN}"
sudo install -m 0755 /tmp/hysteria /usr/local/bin/hysteria
print_first_line /usr/local/bin/hysteria version

echo "=== [5/8] Installing AnyTLS ==="
case "$ARCH" in
  x86_64)  AT_ARCH="amd64" ;;
  aarch64) AT_ARCH="arm64" ;;
esac
AT_VER="$ANYTLS_VERSION"
[ -n "$AT_VER" ] || { echo "ANYTLS_VERSION 不能为空"; exit 1; }
download_file /tmp/anytls.zip \
  "https://github.com/anytls/anytls-go/releases/download/v${AT_VER}/anytls_${AT_VER}_linux_${AT_ARCH}.zip"
sudo rm -rf /tmp/anytls-extract
sudo unzip -oq /tmp/anytls.zip -d /tmp/anytls-extract
sudo install -m 0755 /tmp/anytls-extract/anytls-server /usr/local/bin/anytls-server
echo "anytls-server v${AT_VER} installed"

if [ "${CDN_ENABLE:-false}" = "true" ]; then
  echo "=== [5b] Installing cloudflared ==="
  case "$ARCH" in
    x86_64)  CF_BIN="cloudflared-linux-amd64" ;;
    aarch64) CF_BIN="cloudflared-linux-arm64" ;;
  esac
  download_file /tmp/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${CF_BIN}"
  sudo install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
  print_first_line /usr/local/bin/cloudflared --version
fi

echo "=== [6/8] Generating Reality keypair ==="
REALITY_PRIVATE=""
if [ -f /usr/local/etc/xray/config.json ]; then
  REALITY_PRIVATE="$(sudo awk -F'"' '/"privateKey"/ {print $4; exit}' /usr/local/etc/xray/config.json)"
fi
if [ -n "$REALITY_PRIVATE" ]; then
  KEYS="$(/usr/local/bin/xray x25519 -i "$REALITY_PRIVATE")"
else
  KEYS="$(/usr/local/bin/xray x25519)"
  REALITY_PRIVATE="$(echo "$KEYS" | grep -iE 'private' | awk '{print $NF}')"
fi
REALITY_PUBLIC="$(echo "$KEYS"  | grep -iE 'public|password' | awk '{print $NF}')"
[ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || { echo "x25519 keygen failed"; exit 1; }

echo "=== [7/8] Writing server configs ==="
for svc_user in xray hysteria anytls; do
  if ! id "$svc_user" >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$svc_user"
  fi
done

xray_clients=""; hy2_users=""; first=1
for d in $DEVICES; do
  uuid="$(vv "REALITY_UUID_$d")"
  hy2pw="$(vv "HY2_PASS_$d")"
  [ -n "$uuid" ] && [ -n "$hy2pw" ] || { echo "missing creds for device $d"; exit 1; }
  sep=","; [ $first -eq 1 ] && sep=""
  xray_clients="${xray_clients}${sep}
        {\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}"
  hy2_users="${hy2_users}
    ${d}: ${hy2pw}"
  first=0
done

# CDN 套娃：可选的第二个 xray inbound（VLESS+WS，仅监听 127.0.0.1:8080，无 TLS，
# TLS 由 Cloudflare 边缘终结）。用与 Reality 不同的 per-device uuid，两条链路凭据隔离。
CDN_INBOUND=""
if [ "${CDN_ENABLE:-false}" = "true" ]; then
  : "${CDN_WS_PATH:?CDN_ENABLE=true 但缺 CDN_WS_PATH}"
  cdn_clients=""; cfirst=1
  for d in $DEVICES; do
    cuuid="$(vv "CDN_UUID_$d")"
    [ -n "$cuuid" ] || { echo "missing CDN uuid for device $d"; exit 1; }
    csep=","; [ $cfirst -eq 1 ] && csep=""
    cdn_clients="${cdn_clients}${csep}
          {\"id\": \"$cuuid\"}"
    cfirst=0
  done
  CDN_INBOUND="
    {
      \"listen\": \"127.0.0.1\",
      \"port\": 8080,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [${cdn_clients}
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"wsSettings\": {\"path\": \"/${CDN_WS_PATH}\"}
      }
    }"
fi

DIRECT_INBOUND=""
if [ "${CDN_ONLY:-false}" != "true" ]; then
  DIRECT_INBOUND="
    {
      \"listen\": \"0.0.0.0\",
      \"port\": ${REALITY_PORT},
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [${xray_clients}
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"raw\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"target\": \"${REALITY_TARGET}\",
          \"serverNames\": [\"${REALITY_SNI}\"],
          \"privateKey\": \"${REALITY_PRIVATE}\",
          \"shortIds\": [\"${REALITY_SHORTID}\"]
        }
      }
    }"
fi

XRAY_INBOUNDS="$DIRECT_INBOUND"
if [ -n "$CDN_INBOUND" ]; then
  [ -n "$XRAY_INBOUNDS" ] && XRAY_INBOUNDS="$XRAY_INBOUNDS,"
  XRAY_INBOUNDS="${XRAY_INBOUNDS}${CDN_INBOUND}"
fi
[ -n "$XRAY_INBOUNDS" ] || { echo "没有可用的 Xray 入站" >&2; exit 1; }

sudo mkdir -p /usr/local/etc/xray
sudo tee /usr/local/etc/xray/config.json > /dev/null <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [${XRAY_INBOUNDS}
  ],
  "outbounds": [{"protocol": "freedom"}]
}
JSON
sudo chown root:xray /usr/local/etc/xray/config.json
sudo chmod 640 /usr/local/etc/xray/config.json
sudo /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json

sudo mkdir -p /etc/hysteria
HY2_TLS_BLOCK=""
HY2_ACME_BLOCK=""
if [ "$HY2_ACME_ENABLE" = "true" ]; then
  HY2_ACME_BLOCK="
acme:
  domains:
    - ${HY2_ACME_DOMAIN}
  email: ${HY2_ACME_EMAIL}
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: \"${HY2_ACME_DNS_TOKEN}\""
else
  if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/cert.key ]; then
    sudo openssl ecparam -genkey -name prime256v1 -out /tmp/hy2.key >/dev/null 2>&1
    sudo openssl req -new -x509 -days 3650 -key /tmp/hy2.key \
      -out /etc/hysteria/cert.crt -subj "/CN=${HY2_SNI}" >/dev/null 2>&1
    sudo mv /tmp/hy2.key /etc/hysteria/cert.key
  fi
  sudo chown root:hysteria /etc/hysteria/cert.crt /etc/hysteria/cert.key
  sudo chmod 640 /etc/hysteria/cert.crt /etc/hysteria/cert.key
  HY2_TLS_BLOCK="
tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/cert.key"
fi

HY2_LISTEN="${HY2_PORT}"
HY2_CAPS="CAP_NET_BIND_SERVICE"
if [ -n "$HY2_PORT_RANGE" ]; then
  HY2_LISTEN="$HY2_PORT_RANGE"
  HY2_CAPS="CAP_NET_BIND_SERVICE CAP_NET_ADMIN"
fi
HY2_OBFS_BLOCK=""
if [ "${HY2_OBFS_ENABLE:-false}" = "true" ]; then
  : "${HY2_OBFS_PASSWORD:?HY2_OBFS_ENABLE=true 但缺 HY2_OBFS_PASSWORD}"
  HY2_OBFS_BLOCK="
obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS_PASSWORD}"
fi

sudo tee /etc/hysteria/config.yaml > /dev/null <<YAML
listen: :${HY2_LISTEN}

${HY2_TLS_BLOCK}${HY2_ACME_BLOCK}

auth:
  type: userpass
  userpass:${hy2_users}

masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE_URL}
    rewriteHost: true
${HY2_OBFS_BLOCK}
YAML
sudo chown root:hysteria /etc/hysteria/config.yaml
sudo chmod 640 /etc/hysteria/config.yaml
sudo chown root:hysteria /etc/hysteria
sudo chmod 750 /etc/hysteria

sudo mkdir -p /etc/anytls
printf 'ANYTLS_PASS=%s\n' "$ANYTLS_PASS" | sudo tee /etc/anytls/env > /dev/null
sudo chown -R root:anytls /etc/anytls
sudo chmod 750 /etc/anytls
sudo chmod 640 /etc/anytls/env
sudo tee /usr/local/sbin/anytls-run > /dev/null <<UNIT
#!/bin/sh
set -eu
. /etc/anytls/env
exec /usr/local/bin/anytls-server -l 0.0.0.0:${ANYTLS_PORT} -p "\$ANYTLS_PASS"
UNIT
sudo chown root:root /usr/local/sbin/anytls-run
sudo chmod 755 /usr/local/sbin/anytls-run

# Remove the old Shadowsocks service if this VM was deployed by an earlier kit version.
sudo systemctl disable --now ssserver >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/ssserver.service

sudo tee /etc/systemd/system/xray.service > /dev/null <<'UNIT'
[Unit]
Description=Xray VLESS+Reality server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/usr/local/etc/xray

[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/hysteria.service > /dev/null <<UNIT
[Unit]
Description=Hysteria2 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
AmbientCapabilities=${HY2_CAPS}
CapabilityBoundingSet=${HY2_CAPS}
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/hysteria

[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/anytls.service > /dev/null <<UNIT
[Unit]
Description=AnyTLS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=anytls
Group=anytls
ExecStart=/usr/local/sbin/anytls-run
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/anytls

[Install]
WantedBy=multi-user.target
UNIT

# CDN 套娃：cloudflared（token 模式）。token 经 root-only EnvironmentFile 注入，
# 不出现在 ExecStart / ps。CDN 关闭时停用并清理旧服务。
CDN_SERVICES=""
if [ "${CDN_ENABLE:-false}" = "true" ]; then
  : "${CF_TUNNEL_TOKEN:?CDN_ENABLE=true 但缺 CF_TUNNEL_TOKEN}"
  sudo mkdir -p /etc/cloudflared
  printf 'TUNNEL_TOKEN=%s\n' "$CF_TUNNEL_TOKEN" | sudo tee /etc/cloudflared/env > /dev/null
  sudo chmod 600 /etc/cloudflared/env
  sudo tee /etc/systemd/system/cloudflared.service > /dev/null <<'UNIT'
[Unit]
Description=cloudflared Tunnel (CDN egress)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/cloudflared/env
ExecStart=/usr/local/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
DynamicUser=true

[Install]
WantedBy=multi-user.target
UNIT
  CDN_SERVICES="cloudflared"
else
  sudo systemctl disable --now cloudflared >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/cloudflared.service /etc/cloudflared/env
fi

PROXY_SERVICES="xray hysteria anytls"
if [ "${CDN_ONLY:-false}" = "true" ]; then
  sudo systemctl disable --now hysteria anytls >/dev/null 2>&1 || true
  PROXY_SERVICES="xray"
fi

sudo systemctl daemon-reload
sudo systemctl enable $PROXY_SERVICES $CDN_SERVICES
sudo systemctl restart $PROXY_SERVICES $CDN_SERVICES
sleep 2
sudo systemctl is-active $PROXY_SERVICES $CDN_SERVICES || true

echo "=== [8/8] Hardening (SSH + auto-updates) ==="
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true
sudo sed -i \
  -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
  -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
  /etc/ssh/sshd_config
sudo systemctl reload ssh || sudo systemctl reload sshd || true

echo ""
echo "=== Listening sockets ==="
sudo ss -tulnp | grep -E 'xray|hysteria|anytls|cloudflared|:8080' || true
if [ "${CDN_ENABLE:-false}" = "true" ]; then
  echo "--- cloudflared status ---"
  sudo systemctl is-active cloudflared || true
fi

# machine-readable handoff line — local deployer greps this
echo ""
echo "REALITY_PUBLIC_KEY=${REALITY_PUBLIC}"
echo "=== DONE ==="
