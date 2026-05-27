#!/usr/bin/env bash
# Runs ON the GCP VM. Reads /tmp/server-env.sh for credentials, installs
# Xray (VLESS+Reality), Hysteria2, and AnyTLS, then prints
# REALITY_PUBLIC_KEY=<key> on stdout so the local deployer can pick it up.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

ENV_FILE="${1:-/tmp/server-env.sh}"
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${REALITY_PORT:?}" "${REALITY_SNI:?}" "${REALITY_SHORTID:?}" "${DEVICES:?}"
: "${HY2_PORT:?}" "${ANYTLS_PORT:?}" "${ANYTLS_PASS:?}"

vv() { eval "printf '%s' \"\${$1:-}\""; }   # indirect var read

echo "=== [1/8] Enabling BBR ==="
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
  sudo tee -a /etc/sysctl.conf > /dev/null <<'SYSCTL'

# VPN tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
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
curl -fsSL -o /tmp/xray.zip \
  "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
sudo unzip -oq /tmp/xray.zip -d /usr/local/bin xray
sudo chmod 0755 /usr/local/bin/xray
/usr/local/bin/xray version | head -1

echo "=== [4/8] Installing Hysteria2 ==="
case "$ARCH" in
  x86_64)  HY2_BIN="hysteria-linux-amd64" ;;
  aarch64) HY2_BIN="hysteria-linux-arm64" ;;
esac
curl -fsSL -o /tmp/hysteria \
  "https://github.com/apernet/hysteria/releases/latest/download/${HY2_BIN}"
sudo install -m 0755 /tmp/hysteria /usr/local/bin/hysteria
/usr/local/bin/hysteria version | head -1

echo "=== [5/8] Installing AnyTLS ==="
case "$ARCH" in
  x86_64)  AT_ARCH="amd64" ;;
  aarch64) AT_ARCH="arm64" ;;
esac
AT_VER="$(curl -fsSL https://api.github.com/repos/anytls/anytls-go/releases/latest | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')"
[ -n "$AT_VER" ] || { echo "Failed to fetch anytls latest version"; exit 1; }
curl -fsSL -o /tmp/anytls.zip \
  "https://github.com/anytls/anytls-go/releases/download/v${AT_VER}/anytls_${AT_VER}_linux_${AT_ARCH}.zip"
sudo rm -rf /tmp/anytls-extract
sudo unzip -oq /tmp/anytls.zip -d /tmp/anytls-extract
sudo install -m 0755 /tmp/anytls-extract/anytls-server /usr/local/bin/anytls-server
echo "anytls-server v${AT_VER} installed"

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

sudo mkdir -p /usr/local/etc/xray
sudo tee /usr/local/etc/xray/config.json > /dev/null <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [${xray_clients}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE}",
          "shortIds": ["${REALITY_SHORTID}"]
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
JSON
sudo chmod 644 /usr/local/etc/xray/config.json

sudo mkdir -p /etc/hysteria
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/cert.key ]; then
  sudo openssl ecparam -genkey -name prime256v1 -out /tmp/hy2.key >/dev/null 2>&1
  sudo openssl req -new -x509 -days 3650 -key /tmp/hy2.key \
    -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com" >/dev/null 2>&1
  sudo mv /tmp/hy2.key /etc/hysteria/cert.key
fi
sudo chmod 644 /etc/hysteria/cert.crt /etc/hysteria/cert.key

sudo tee /etc/hysteria/config.yaml > /dev/null <<YAML
listen: :${HY2_PORT}

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/cert.key

auth:
  type: userpass
  userpass:${hy2_users}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
YAML
sudo chmod 644 /etc/hysteria/config.yaml

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
DynamicUser=true

[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/hysteria.service > /dev/null <<'UNIT'
[Unit]
Description=Hysteria2 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/hysteria
DynamicUser=true

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
ExecStart=/usr/local/bin/anytls-server -l 0.0.0.0:${ANYTLS_PORT} -p ${ANYTLS_PASS}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
DynamicUser=true

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable xray hysteria anytls
sudo systemctl restart xray hysteria anytls
sleep 2
sudo systemctl is-active xray hysteria anytls || true

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
sudo ss -tulnp | grep -E 'xray|hysteria|anytls' || true

# machine-readable handoff line — local deployer greps this
echo ""
echo "REALITY_PUBLIC_KEY=${REALITY_PUBLIC}"
echo "=== DONE ==="
