#!/usr/bin/env python3
"""Generate Clash.Meta / Mihomo YAML configs, one per device.

Reads deploy.conf (DEVICES, REALITY_PORT, REALITY_SNI, PROJECT_ID, REGION) and
.secrets.env (STATIC_IP, REALITY_PUBLIC, REALITY_SHORTID, HY2_PORT,
ANYTLS_PORT, ANYTLS_PASS, and per-device REALITY_UUID_<dev> / HY2_PASS_<dev>).

Each device gets its OWN Reality UUID and Hysteria2 password so a single device
can be revoked without affecting the others. Primary node is VLESS+Reality;
Hysteria2 and AnyTLS are fallback options for compatible Mihomo clients.
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT_DIR = HERE / "clash-configs"


def load_kv(path):
    data = {}
    if not path.exists():
        return data
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip().strip('"').strip("'")
    return data


env = {}
env.update(load_kv(HERE / "deploy.conf"))
env.update(load_kv(HERE / ".secrets.env"))

REQUIRED = [
    "STATIC_IP",
    "REALITY_PORT", "REALITY_SNI", "REALITY_PUBLIC", "REALITY_SHORTID",
    "HY2_PORT",
    "ANYTLS_PORT", "ANYTLS_PASS",
]
missing = [k for k in REQUIRED if not env.get(k)]
if missing:
    sys.exit(f"ERROR: 缺少必要变量 {missing}（应由 deploy.sh 自动生成，请检查 .secrets.env）")

devices = env.get("DEVICES", "mac iphone ipad laptop spare").split()

# ── CDN 套娃出口（可选）──
# 启用条件：CDN_ENABLE=true 且 CF/WS 参数齐全。启用时把 US-CDN 作为一个普通节点
# 加入现有节点池（节点策略 / 自动测速 / 手动选择），分流规则完全不变；
# 关闭时所有 CDN 占位符为空，与历史行为完全一致（向后兼容）。
CDN_HOSTNAME = env.get("CDN_HOSTNAME", "")
CDN_WS_PATH = env.get("CDN_WS_PATH", "").lstrip("/")
cdn_on = env.get("CDN_ENABLE", "false") == "true" and bool(CDN_HOSTNAME) and bool(CDN_WS_PATH)
CDN_REF = '\n      - "US-CDN"' if cdn_on else ""


def cdn_proxy_block(dev_cdn_uuid):
    """US-CDN 节点（VLESS+WS+TLS，经 Cloudflare）。CDN 关闭时返回空串。"""
    if not cdn_on:
        return ""
    return (
        '  - name: "US-CDN"\n'
        "    type: vless\n"
        f"    server: {CDN_HOSTNAME}\n"
        "    port: 443\n"
        f"    uuid: {dev_cdn_uuid}\n"
        "    network: ws\n"
        "    tls: true\n"
        "    udp: true\n"
        f"    servername: {CDN_HOSTNAME}\n"
        "    client-fingerprint: chrome\n"
        "    ws-opts:\n"
        f'      path: "/{CDN_WS_PATH}"\n'
        "      headers:\n"
        f"        Host: {CDN_HOSTNAME}\n"
    )

TEMPLATE = """# Clash.Meta / Mihomo config — device: {DEVICE}
# Server: {STATIC_IP}  |  primary: VLESS+Reality:{REALITY_PORT}  |  fallback: Hysteria2:{HY2_PORT}/udp, AnyTLS:{ANYTLS_PORT}/tcp

mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
geodata-mode: true
find-process-mode: strict
global-client-fingerprint: chrome

sniffer:
  enable: true
  override-destination: true
  sniff:
    - tls
    - http

skip-proxy:
  - 127.0.0.1
  - 192.168.0.0/16
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 100.64.0.0/10
  - localhost
  - "*.local"
  - captive.apple.com

tun:
  enable: true
  stack: system
  mtu: 1280
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - "any:53"

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.apple.com"
    - "*.apple"
    - "app-analytics-services.com"
    - "time.*.com"
    - "ntp.*.com"
    - "*.ntp.org"
    - "stun.*"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "localhost.ptlogin2.qq.com"
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

proxies:
  - name: "US-Reality"
    type: vless
    server: {STATIC_IP}
    port: {REALITY_PORT}
    uuid: {DEV_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: {REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: {REALITY_PUBLIC}
      short-id: "{REALITY_SHORTID}"

  - name: "US-HY2"
    type: hysteria2
    server: {STATIC_IP}
    port: {HY2_PORT}
    password: "{HY2_PASSWORD}"
    sni: www.bing.com
    skip-cert-verify: true
    alpn:
      - h3

  - name: "US-AnyTLS"
    type: anytls
    server: {STATIC_IP}
    port: {ANYTLS_PORT}
    password: "{ANYTLS_PASS}"
    sni: www.bing.com
    skip-cert-verify: true
    client-fingerprint: chrome
    udp: true
{CDN_PROXY}
proxy-groups:
  - name: "🚦 节点策略"
    type: select
    proxies:
      - "⚡ 自动测速"
      - "🔧 手动选择"{CDN_REF}
      - "US-Reality"
      - "US-HY2"
      - "US-AnyTLS"
      - DIRECT

  - name: "⚡ 自动测速"
    type: url-test
    lazy: true
    url: https://www.gstatic.com/generate_204
    interval: 600
    tolerance: 150
    proxies:{CDN_REF}
      - "US-Reality"
      - "US-HY2"
      - "US-AnyTLS"

  - name: "🔧 手动选择"
    type: select
    proxies:{CDN_REF}
      - "US-Reality"
      - "US-HY2"
      - "US-AnyTLS"
      - DIRECT

  - name: "🌐 代理流量"
    type: select
    proxies:
      - "🚦 节点策略"
      - "⚡ 自动测速"
      - "🔧 手动选择"
      - "US-Reality"
      - "US-HY2"
      - "US-AnyTLS"
      - DIRECT
      - REJECT

  - name: "↪️ 直连流量"
    type: select
    proxies:
      - DIRECT
      - "🚦 节点策略"
      - "⚡ 自动测速"
      - "🔧 手动选择"
      - "US-Reality"
      - "US-HY2"
      - "US-AnyTLS"
      - REJECT

  - name: "🛑 屏蔽流量"
    type: select
    proxies:
      - REJECT
      - DIRECT
      - "🚦 节点策略"
      - "⚡ 自动测速"
      - "🔧 手动选择"
      - "US-Reality"
      - "US-HY2"
      - "US-AnyTLS"

  - name: "🎯 兜底策略"
    type: select
    proxies:
      - "🚦 节点策略"
      - DIRECT
      - REJECT
      - "⚡ 自动测速"
      - "🔧 手动选择"
      - "US-Reality"
      - "US-HY2"
      - "US-AnyTLS"

rule-providers:
  # 广告/追踪域名拦截清单（借鉴 Stash：远程清单，每天自动更新；需 Mihomo/Clash.Meta）
  reject:
    type: http
    behavior: domain
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt"
    path: ./ruleset/reject.yaml
    interval: 86400

rules:
  # --- [P0] 规则集保活：raw 直连，确保 reject 清单能拉到/更新 ---
  - DOMAIN-SUFFIX,raw.githubusercontent.com,↪️ 直连流量

  # --- Local / private networks: always DIRECT ---
  - DOMAIN-SUFFIX,lan,DIRECT
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve

  # --- Proxy allowlist: anti-restrict, global sites, attribution/business dashboards ---
  - DOMAIN-SUFFIX,openai.com,🌐 代理流量
  - DOMAIN-SUFFIX,chatgpt.com,🌐 代理流量
  - DOMAIN-SUFFIX,oaistatic.com,🌐 代理流量
  - DOMAIN-SUFFIX,oaiusercontent.com,🌐 代理流量
  - DOMAIN-KEYWORD,openai,🌐 代理流量
  - DOMAIN-SUFFIX,anthropic.com,🌐 代理流量
  - DOMAIN-SUFFIX,claude.ai,🌐 代理流量
  - DOMAIN-SUFFIX,claudeusercontent.com,🌐 代理流量
  - DOMAIN-SUFFIX,dify.ai,🌐 代理流量
  - DOMAIN-SUFFIX,coze.com,🌐 代理流量
  - DOMAIN-SUFFIX,gemini.google.com,🌐 代理流量
  - DOMAIN-SUFFIX,bard.google.com,🌐 代理流量
  - DOMAIN-SUFFIX,makersuite.google.com,🌐 代理流量
  - DOMAIN-SUFFIX,aistudio.google.com,🌐 代理流量
  - DOMAIN-SUFFIX,generativelanguage.googleapis.com,🌐 代理流量
  - DOMAIN-SUFFIX,perplexity.ai,🌐 代理流量
  - DOMAIN-SUFFIX,pplx.ai,🌐 代理流量
  - DOMAIN-SUFFIX,x.ai,🌐 代理流量
  - DOMAIN-SUFFIX,grok.com,🌐 代理流量
  - DOMAIN-SUFFIX,mistral.ai,🌐 代理流量
  - DOMAIN-SUFFIX,huggingface.co,🌐 代理流量
  - DOMAIN-SUFFIX,character.ai,🌐 代理流量
  - DOMAIN-SUFFIX,poe.com,🌐 代理流量
  - DOMAIN-SUFFIX,cohere.ai,🌐 代理流量
  - DOMAIN-SUFFIX,cohere.com,🌐 代理流量
  - DOMAIN-SUFFIX,stability.ai,🌐 代理流量
  - DOMAIN-SUFFIX,replicate.com,🌐 代理流量
  - DOMAIN-SUFFIX,runwayml.com,🌐 代理流量
  - DOMAIN-SUFFIX,midjourney.com,🌐 代理流量
  - DOMAIN-SUFFIX,ads.google.com,🌐 代理流量
  - DOMAIN-SUFFIX,adwords.google.com,🌐 代理流量
  - DOMAIN-SUFFIX,analytics.google.com,🌐 代理流量
  - DOMAIN-SUFFIX,googletagmanager.com,🌐 代理流量
  - DOMAIN-SUFFIX,googleadservices.com,🌐 代理流量
  - DOMAIN-SUFFIX,googlesyndication.com,🌐 代理流量
  - DOMAIN-SUFFIX,googletagservices.com,🌐 代理流量
  - DOMAIN-SUFFIX,ads.tiktok.com,🌐 代理流量
  - DOMAIN-SUFFIX,business.tiktok.com,🌐 代理流量
  - DOMAIN-SUFFIX,tradingview.com,🌐 代理流量
  - DOMAIN,dash.applovin.com,🌐 代理流量
  - DOMAIN-SUFFIX,applovin.com,🌐 代理流量
  - DOMAIN-SUFFIX,applvn.com,🌐 代理流量
  - DOMAIN-SUFFIX,applovinedge.com,🌐 代理流量
  - DOMAIN-SUFFIX,appsflyer.com,🌐 代理流量
  - DOMAIN,suite.adjust.com,🌐 代理流量
  - DOMAIN-SUFFIX,adjust.com,🌐 代理流量
  - DOMAIN-SUFFIX,adj.st,🌐 代理流量
  - DOMAIN-SUFFIX,kochava.com,🌐 代理流量
  - DOMAIN-SUFFIX,branch.io,🌐 代理流量
  - DOMAIN-SUFFIX,singular.net,🌐 代理流量
  # --- 特殊域名（借鉴 Stash）：Siri 走代理（须在 apple 直连之前）、金融、Telegram ---
  - DOMAIN-SUFFIX,guzzoni.apple.com,🌐 代理流量
  # iCloud 私人中继（入口 gateway + 三家出口 egress）+ 连通性探测 + 定位/AppStore。
  # 必须排在下方 apple.com / icloud.com / mzstatic.com 的「直连」规则之前，否则被吞。
  - DOMAIN-SUFFIX,apple-relay.apple.com,🌐 代理流量
  - DOMAIN-SUFFIX,apple-relay.fastly-edge.com,🌐 代理流量
  - DOMAIN-SUFFIX,apple-relay.cloudflare.com,🌐 代理流量
  - DOMAIN-SUFFIX,gateway.icloud.com,🌐 代理流量
  - DOMAIN-SUFFIX,cp4.cloudflare.com,🌐 代理流量
  - DOMAIN-SUFFIX,gspe1-ssl.ls.apple.com,🌐 代理流量
  - DOMAIN-SUFFIX,apps.mzstatic.com,🌐 代理流量
  - DOMAIN-SUFFIX,okx.com,🌐 代理流量
  - DOMAIN-SUFFIX,binance.com,🌐 代理流量
  - DOMAIN-SUFFIX,bybit.com,🌐 代理流量
  - DOMAIN-SUFFIX,gate.io,🌐 代理流量
  - DOMAIN-SUFFIX,interactivebrokers.com,🌐 代理流量
  - DOMAIN-SUFFIX,webull.com,🌐 代理流量
  - DOMAIN-SUFFIX,telegram.org,🌐 代理流量
  - DOMAIN-SUFFIX,t.me,🌐 代理流量
  - DOMAIN-KEYWORD,telegram,🌐 代理流量
  - DOMAIN-SUFFIX,google.com,🌐 代理流量
  - DOMAIN-SUFFIX,googleapis.com,🌐 代理流量
  - DOMAIN-SUFFIX,gstatic.com,🌐 代理流量
  - DOMAIN-SUFFIX,ggpht.com,🌐 代理流量
  - DOMAIN-SUFFIX,googleusercontent.com,🌐 代理流量
  - DOMAIN-SUFFIX,youtube.com,🌐 代理流量
  - DOMAIN-SUFFIX,youtu.be,🌐 代理流量
  - DOMAIN-SUFFIX,ytimg.com,🌐 代理流量
  - DOMAIN-SUFFIX,googlevideo.com,🌐 代理流量
  - DOMAIN-SUFFIX,gmail.com,🌐 代理流量
  - DOMAIN-SUFFIX,github.com,🌐 代理流量
  - DOMAIN-SUFFIX,githubusercontent.com,🌐 代理流量
  - DOMAIN-SUFFIX,githubassets.com,🌐 代理流量
  - DOMAIN-SUFFIX,twitter.com,🌐 代理流量
  - DOMAIN-SUFFIX,x.com,🌐 代理流量
  - DOMAIN-SUFFIX,twimg.com,🌐 代理流量
  - DOMAIN-SUFFIX,reddit.com,🌐 代理流量
  - DOMAIN-SUFFIX,redditstatic.com,🌐 代理流量
  - DOMAIN-SUFFIX,redd.it,🌐 代理流量
  - DOMAIN-SUFFIX,wikipedia.org,🌐 代理流量
  - DOMAIN-SUFFIX,wikimedia.org,🌐 代理流量
  - DOMAIN-SUFFIX,stackoverflow.com,🌐 代理流量
  - DOMAIN-SUFFIX,medium.com,🌐 代理流量

  # --- Direct allowlist: CN domains, Apple, domestic work platforms ---
  - DOMAIN-SUFFIX,e.kuaishou.com,↪️ 直连流量
  - DOMAIN-SUFFIX,business.oceanengine.com,↪️ 直连流量
  - DOMAIN-SUFFIX,cas.baidu.com,↪️ 直连流量
  - DOMAIN-SUFFIX,e.qq.com,↪️ 直连流量
  - DOMAIN-SUFFIX,oceanengine.com,↪️ 直连流量
  - DOMAIN-SUFFIX,kylin.baidu.com,↪️ 直连流量
  - DOMAIN-SUFFIX,apple.com,↪️ 直连流量
  - DOMAIN-SUFFIX,icloud.com,↪️ 直连流量
  - DOMAIN-SUFFIX,cdn-apple.com,↪️ 直连流量
  - DOMAIN-SUFFIX,mzstatic.com,↪️ 直连流量
  - DOMAIN-SUFFIX,cn,↪️ 直连流量
  - DOMAIN-KEYWORD,-cn,↪️ 直连流量
  - DOMAIN-SUFFIX,baidu.com,↪️ 直连流量
  - DOMAIN-SUFFIX,qq.com,↪️ 直连流量
  - DOMAIN-SUFFIX,weixin.qq.com,↪️ 直连流量
  - DOMAIN-SUFFIX,bilibili.com,↪️ 直连流量
  - DOMAIN-SUFFIX,taobao.com,↪️ 直连流量
  - DOMAIN-SUFFIX,tmall.com,↪️ 直连流量
  - DOMAIN-SUFFIX,alipay.com,↪️ 直连流量
  - DOMAIN-SUFFIX,zhihu.com,↪️ 直连流量
  - DOMAIN-SUFFIX,douban.com,↪️ 直连流量
  - DOMAIN-SUFFIX,sina.com.cn,↪️ 直连流量
  - DOMAIN-SUFFIX,163.com,↪️ 直连流量
  - DOMAIN-SUFFIX,126.com,↪️ 直连流量
  - DOMAIN-SUFFIX,douyin.com,↪️ 直连流量
  - DOMAIN-SUFFIX,xiaohongshu.com,↪️ 直连流量
  # 流媒体（netflix/hulu/disney+/hbomax/peacock 等）不再硬编码直连，
  # 落到下方 MATCH→兜底→代理，与 Stash（proxy.txt 兜到代理）一致。

  # --- Spotify 直连（借鉴 Stash）---
  - DOMAIN-KEYWORD,spotify,↪️ 直连流量
  - DOMAIN-SUFFIX,scdn.co,↪️ 直连流量

  # --- 广告/追踪拦截（借鉴 Stash：放在精确放行之后、兜底之前，不误伤业务/归因域名）---
  - RULE-SET,reject,🛑 屏蔽流量

  # --- GeoIP fallback ---
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - GEOIP,CN,↪️ 直连流量

  # --- Default ---
  - MATCH,🎯 兜底策略
"""

OUT_DIR.mkdir(exist_ok=True)
for dev in devices:
    uuid = env.get(f"REALITY_UUID_{dev}")
    hy2pw = env.get(f"HY2_PASS_{dev}")
    if not uuid or not hy2pw:
        sys.exit(f"ERROR: 设备 {dev} 缺少 REALITY_UUID_{dev} / HY2_PASS_{dev}")
    dev_cdn_uuid = env.get(f"CDN_UUID_{dev}", "")
    if cdn_on and not dev_cdn_uuid:
        sys.exit(f"ERROR: CDN_ENABLE=true 但设备 {dev} 缺少 CDN_UUID_{dev}")
    yaml = TEMPLATE.format(
        DEVICE=dev,
        DEV_UUID=uuid,
        HY2_PASSWORD=f"{dev}:{hy2pw}",
        CDN_PROXY=cdn_proxy_block(dev_cdn_uuid),
        CDN_REF=CDN_REF,
        **env,
    )
    path = OUT_DIR / f"{dev}.yaml"
    path.write_text(yaml)
    print(f"  wrote {path.name} ({len(yaml)} bytes)")

print(f"\n全部 {len(devices)} 份配置已写入 {OUT_DIR}")
