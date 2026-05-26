#!/usr/bin/env bash
# Runs ON the GCP VM. Reads /tmp/server-env.sh for credentials, installs
# shadowsocks-rust (SS-2022 EIH multi-user) + Xray (VLESS+Reality), then prints
# REALITY_PUBLIC_KEY=<key> on stdout so the local deployer can pick it up.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

ENV_FILE="${1:-/tmp/server-env.sh}"
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${SS_PORT:?}" "${SS_IPSK:?}" "${REALITY_PORT:?}" "${REALITY_SNI:?}" "${REALITY_SHORTID:?}" "${DEVICES:?}"

vv() { eval "printf '%s' \"\${$1:-}\""; }   # indirect var read

echo "=== [1/7] Enabling BBR ==="
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
  sudo tee -a /etc/sysctl.conf > /dev/null <<'SYSCTL'

# VPN tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
fi
sudo sysctl -p > /dev/null
sysctl net.ipv4.tcp_congestion_control

echo "=== [2/7] Installing prerequisites ==="
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip xz-utils

ARCH="$(uname -m)"

echo "=== [3/7] Installing shadowsocks-rust ==="
SS_VER="v1.22.0"
case "$ARCH" in
  x86_64)  SS_TARGET="x86_64-unknown-linux-gnu" ;;
  aarch64) SS_TARGET="aarch64-unknown-linux-gnu" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
curl -fsSL -o /tmp/ss.tar.xz \
  "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VER}/shadowsocks-${SS_VER}.${SS_TARGET}.tar.xz"
tar -C /tmp -xf /tmp/ss.tar.xz ssserver
sudo install -m 0755 /tmp/ssserver /usr/local/bin/ssserver
/usr/local/bin/ssserver --version

echo "=== [4/7] Installing Xray ==="
case "$ARCH" in
  x86_64)  XRAY_ZIP="Xray-linux-64.zip" ;;
  aarch64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
esac
curl -fsSL -o /tmp/xray.zip \
  "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
sudo unzip -oq /tmp/xray.zip -d /usr/local/bin xray
sudo chmod 0755 /usr/local/bin/xray
/usr/local/bin/xray version | head -1

echo "=== [5/7] Generating Reality keypair ==="
KEYS="$(/usr/local/bin/xray x25519)"
REALITY_PRIVATE="$(echo "$KEYS" | grep -iE 'private' | awk '{print $NF}')"
REALITY_PUBLIC="$(echo "$KEYS"  | grep -iE 'public|password' | awk '{print $NF}')"
[ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || { echo "x25519 keygen failed"; exit 1; }

echo "=== [6/7] Writing server configs ==="
# --- shadowsocks users array ---
ss_users=""; xray_clients=""; first=1
for d in $DEVICES; do
  upsk="$(vv "SS_UPSK_$d")"
  uuid="$(vv "REALITY_UUID_$d")"
  [ -n "$upsk" ] && [ -n "$uuid" ] || { echo "missing creds for device $d"; exit 1; }
  sep=","; [ $first -eq 1 ] && sep=""
  ss_users="${ss_users}${sep}
    {\"name\": \"$d\", \"password\": \"$upsk\"}"
  xray_clients="${xray_clients}${sep}
        {\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}"
  first=0
done

sudo mkdir -p /etc/shadowsocks
sudo tee /etc/shadowsocks/config.json > /dev/null <<JSON
{
  "server": "0.0.0.0",
  "server_port": ${SS_PORT},
  "method": "2022-blake3-aes-128-gcm",
  "password": "${SS_IPSK}",
  "mode": "tcp_and_udp",
  "fast_open": false,
  "users": [${ss_users}
  ]
}
JSON
sudo chmod 644 /etc/shadowsocks/config.json

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

# --- systemd units ---
sudo tee /etc/systemd/system/ssserver.service > /dev/null <<'UNIT'
[Unit]
Description=shadowsocks-rust server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/shadowsocks
DynamicUser=true

[Install]
WantedBy=multi-user.target
UNIT

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

sudo systemctl daemon-reload
sudo systemctl enable ssserver xray
sudo systemctl restart ssserver xray
sleep 2
sudo systemctl is-active ssserver xray || true

echo "=== [7/7] Hardening (SSH + auto-updates) ==="
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
sudo ss -tulnp | grep -E 'ssserver|xray' || true

# machine-readable handoff line — local deployer greps this
echo ""
echo "REALITY_PUBLIC_KEY=${REALITY_PUBLIC}"
echo "=== DONE ==="
