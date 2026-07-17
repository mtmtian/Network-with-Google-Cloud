#!/usr/bin/env bash
# 幂等地在 Cloudflare 上为本 VM 建一条独立 Tunnel + 配 ingress + DNS，
# 并把 cloudflared 的 connector token 写入 .secrets.env（CF_TUNNEL_TOKEN）。
# 需要 .secrets.env 里有 CF_API_TOKEN（权限 Account>Cloudflare Tunnel:Edit + Zone>Zone:Read + Zone>DNS:Edit）。
# 仅在 CDN_ENABLE=true 时由共享部署流水线调用。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$PROJECT_DIR/core/common.sh"
load_conf
load_secrets

[ "${CDN_ENABLE:-false}" = "true" ] || { ok "CDN_ENABLE!=true，跳过 Cloudflare 配置"; exit 0; }

: "${CDN_HOSTNAME:?deploy.conf 缺少 CDN_HOSTNAME}"
: "${CDN_TUNNEL_NAME:=vpn-us-cdn}"
CF_API_TOKEN="$(secret_get CF_API_TOKEN)"
[ -n "$CF_API_TOKEN" ] || die "缺 CF_API_TOKEN，请写入 .secrets.env（见 secrets.sh 提示）后重跑"
command -v curl >/dev/null 2>&1 || die "缺少 curl，无法调用 Cloudflare API"
command -v python3 >/dev/null 2>&1 || die "缺少 python3，无法解析 Cloudflare API 响应"

API="https://api.cloudflare.com/client/v4"

# cf_api METHOD PATH [json-body] -> 打印响应体；失败重试 3 次；HTTP/业务失败时 die
cf_api() {
  local method="$1" path="$2" body="${3:-}" attempt resp http delay=2
  for attempt in 1 2 3; do
    if [ -n "$body" ]; then
      resp="$(curl -sS -w $'\n%{http_code}' -X "$method" "$API$path" \
        --connect-timeout 15 --max-time 60 \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" --data "$body" 2>/dev/null || true)"
    else
      resp="$(curl -sS -w $'\n%{http_code}' -X "$method" "$API$path" \
        --connect-timeout 15 --max-time 60 \
        -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
    fi
    http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
    if printf '%s' "$resp" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("success") else 1)' 2>/dev/null; then
      printf '%s' "$resp"; return 0
    fi
    if [ "$attempt" -lt 3 ]; then warn "CF API $method $path 失败(HTTP $http)，${delay}s 后重试..."; sleep "$delay"; delay=$((delay*2)); fi
  done
  # 最终失败：打印 CF 的错误信息（不含 token）
  local msg
  msg="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print("; ".join(e.get("message","") for e in d.get("errors",[])) or d)
except Exception: print("无法解析响应")' 2>/dev/null)"
  case "$msg" in
    *9109*|*[Aa]uthentication*|*[Tt]oken*) die "CF API 鉴权失败：$msg（确认 token 含 Account>Cloudflare Tunnel:Edit + Zone>DNS:Edit）" ;;
    *) die "CF API $method $path 失败：$msg" ;;
  esac
}

jget() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)" 2>/dev/null; }

say "[CF 1/5] 定位 zone（匹配 $CDN_HOSTNAME 的最长后缀）"
ZONES_JSON="$(cf_api GET "/zones?per_page=50&status=active")"
read -r ZONE_ID ACCOUNT_ID ZONE_NAME <<EOF
$(printf '%s' "$ZONES_JSON" | python3 -c '
import sys,json
host=sys.argv[1]
d=json.load(sys.stdin)
best=None
for z in d.get("result",[]):
    n=z["name"]
    if host==n or host.endswith("."+n):
        if best is None or len(n)>len(best["name"]): best=z
if best: print(best["id"], best["account"]["id"], best["name"])
' "$CDN_HOSTNAME")
EOF
[ -n "${ZONE_ID:-}" ] || die "在该 Cloudflare 账号下找不到 $CDN_HOSTNAME 对应的 zone，请先把域名接入 Cloudflare"
ok "zone=$ZONE_NAME  account=$ACCOUNT_ID"

say "[CF 2/5] 建/复用 Tunnel：$CDN_TUNNEL_NAME"
LIST_JSON="$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$CDN_TUNNEL_NAME&is_deleted=false")"
TUNNEL_ID="$(printf '%s' "$LIST_JSON" | jget '["result"][0]["id"]' || true)"
if [ -z "$TUNNEL_ID" ] || [ "$TUNNEL_ID" = "None" ]; then
  CREATE_JSON="$(cf_api POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
    "{\"name\":\"$CDN_TUNNEL_NAME\",\"config_src\":\"cloudflare\"}")"
  TUNNEL_ID="$(printf '%s' "$CREATE_JSON" | jget '["result"]["id"]')"
  ok "新建 tunnel：$TUNNEL_ID"
else
  ok "复用已存在 tunnel：$TUNNEL_ID"
fi
[ -n "$TUNNEL_ID" ] && [ "$TUNNEL_ID" != "None" ] || die "未取得 tunnel id"

say "[CF 3/5] 配置 ingress：$CDN_HOSTNAME -> http://localhost:8080"
cf_api PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  "{\"config\":{\"ingress\":[{\"hostname\":\"$CDN_HOSTNAME\",\"service\":\"http://localhost:8080\"},{\"service\":\"http_status:404\"}]}}" >/dev/null
ok "ingress 已设置"

say "[CF 4/5] 配置 DNS：$CDN_HOSTNAME CNAME -> $TUNNEL_ID.cfargotunnel.com (proxied)"
DNS_JSON="$(cf_api GET "/zones/$ZONE_ID/dns_records?type=CNAME&name=$CDN_HOSTNAME")"
REC_ID="$(printf '%s' "$DNS_JSON" | jget '["result"][0]["id"]' || true)"
DNS_BODY="{\"type\":\"CNAME\",\"name\":\"$CDN_HOSTNAME\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}"
if [ -z "$REC_ID" ] || [ "$REC_ID" = "None" ]; then
  cf_api POST "/zones/$ZONE_ID/dns_records" "$DNS_BODY" >/dev/null
  ok "DNS 记录已创建"
else
  cf_api PUT "/zones/$ZONE_ID/dns_records/$REC_ID" "$DNS_BODY" >/dev/null
  ok "DNS 记录已更新"
fi

say "[CF 5/5] 取 connector token 写入 .secrets.env"
TOKEN_JSON="$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token")"
CONNECTOR_TOKEN="$(printf '%s' "$TOKEN_JSON" | jget '["result"]' || true)"
[ -n "$CONNECTOR_TOKEN" ] && [ "$CONNECTOR_TOKEN" != "None" ] || die "未取得 connector token"
setkv CF_TUNNEL_TOKEN "$CONNECTOR_TOKEN"
setkv CDN_TUNNEL_ID "$TUNNEL_ID"
ok "Cloudflare 就绪（tunnel + ingress + DNS + token 完成）"
