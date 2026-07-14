# Self-hosted Network Node

一套共享代理核心，两个明确入口：自动创建 Google Cloud 节点，或部署到任意已有 Debian/Ubuntu VPS。

One shared proxy core with two explicit deployment paths: Google Cloud or any existing Debian/Ubuntu VPS.

- Primary: VLESS + Reality
- UDP fallback: Hysteria2
- TCP fallback: AnyTLS
- One credential set and YAML per device

## 快速开始

公共依赖：本机安装 `python3`、`openssl` 和 OpenSSH。

### Google Cloud

先安装并登录 `gcloud`，然后运行：

```bash
gcloud auth login
gcloud config set project <你的项目ID>
./deploy-gcp.sh
```

GCP adapter 会预留静态 IP、配置云防火墙、创建 Debian VM，并通过 IAP SSH 安装服务端。

### 已有 Debian/Ubuntu VPS

VPS 安装 Debian/Ubuntu，并把本机公钥加入初始 root 账户，然后运行：

```bash
VPS_PROFILE=frantech \
VPS_SSH_KEY="$HOME/.ssh/frantech_ed25519" \
./deploy-vps.sh <VPS_PUBLIC_IP>
```

`VPS_PROFILE` 必须为每台 VPS 使用一个唯一名称，例如 `dmit`、`frantech`、`new-york-01`。
不要裸跑 `./deploy-vps.sh`，这样可以避免新服务器误用已有 profile。

VPS adapter 会执行以下安全步骤：

1. 验证初始 root 公钥登录。
2. 创建并验证独立的 `mt` sudo 用户。
3. 配置 UFW，只开放 SSH 和三个代理端口。
4. 确认 `mt` 可以登录后才禁用 root 和密码登录。
5. 安装三套协议并生成设备 YAML。

重跑时会直接复用已经创建的 `mt` 用户，不再依赖 root。

不要把私钥复制到服务器、Git 跟踪文件或聊天中。

首次部署后可以把主机专用私钥放在 `profiles/<profile>/ssh/`，也可以继续通过
`VPS_SSH_KEY=/path/to/private-key` 显式指定。后续重跑时使用同一个 `VPS_PROFILE`，脚本会复用该 profile 的 IP、端口和本地密钥。

## 目录结构

```text
deploy-gcp.sh / deploy-vps.sh   用户入口
deploy.sh                       旧 GCP 命令的兼容入口
providers/                      GCP、普通 VPS adapter
core/                           共享部署流水线、密钥、协议安装、规则与 YAML 生成
config/                         不含密钥的配置模板
docs/                           架构说明与排障文档
tools/vps_stock.py              只读 VPS 库存监控
profiles/<profile>/             每台服务器独立状态与 ssh/（不提交）
clash-configs/                  所有 profile 的客户端 YAML（不提交）
```

GCP 和 VPS 真正变化的只有服务器生命周期、连接方式与防火墙；协议和客户端规则只维护一份。详细 seam 和 provider interface 见 [架构说明](docs/architecture.md)。

## 配置

首次运行会从 `config/deploy.conf.example` 创建当前 profile 的本地状态。GCloud 固定使用
`profiles/gcloud/`；普通 VPS 使用 `VPS_PROFILE` 对应的 `profiles/<profile>/`。整个
`profiles/` 目录都已被 Git 忽略。

| 配置 | 默认值 | 说明 |
|---|---|---|
| `REALITY_PORT` | `443` | Reality 监听端口 |
| `REALITY_TARGET` / `REALITY_SNI` | `1.1.1.1:443` / 空 | Reality 目标与客户端 SNI |
| `HY2_PORT` | 随机 | Hysteria2 UDP 端口 |
| `ANYTLS_PORT` | 随机 | AnyTLS TCP 端口 |
| `DEVICES` | `mac iphone` | 每个设备生成独立凭据和 YAML |
| `CDN_ENABLE` | `false` | 可选 Cloudflare Tunnel 出口 |
| `PROJECT_ID` / `REGION` / `ZONE` | GCP 默认值 | 只由 GCP adapter 使用 |

每个 profile 内的敏感文件均已 gitignore：

- `.secrets.env`
- `deploy.conf`
- `ssh/`

不要提交、转发或粘贴这些文件的内容。

## 导入客户端

部署成功后，每个平台默认得到两份名称明确的 YAML：

- `clash-configs/gcloud-mac.yaml`
- `clash-configs/gcloud-iphone.yaml`
- `clash-configs/<profile>-mac.yaml`
- `clash-configs/<profile>-iphone.yaml`

生成器只替换当前 profile 前缀的文件，例如 `frantech` 只处理 `frantech-*.yaml`，不会覆盖
`dmit-*.yaml` 或 `gcloud-*.yaml`。客户端 YAML 默认权限为 `600`，因为其中含节点地址、UUID 和密码；
这可阻止同一台电脑上的其他系统用户读取。iCloud 副本用于设备同步，不作为项目源状态。

- Clash Verge：Settings → Profiles → Import
- 手机：使用支持 Reality、Hysteria2 和 AnyTLS 的 Mihomo/Clash.Meta 兼容客户端

修改 `DEVICES` 后重跑同一个 profile 的入口，即可增加或撤销设备。

## 重跑与维护

- 两个入口均按幂等方式设计，会复用已有服务器和本地密钥。
- 只重新生成某个 profile 的客户端 YAML：`NETWORK_NODE_PROFILE=<profile> python3 core/gen-clash.py`
- GCP 旧命令 `./deploy.sh` 仍可使用，但会提示改用 `./deploy-gcp.sh`。
- 通用排障见 [Troubleshooting](docs/troubleshooting.md)。
- 新服务器接入和隔离规则见 [Provider Onboarding](docs/provider-onboarding.md)。
- VPS 库存监控见 [VPS Stock Monitor](docs/vps-stock-monitor.md)。

## VPS 库存监控

从仓库根目录运行只读检查：

```bash
python3 tools/vps_stock.py --state-file ~/.cache/network-node/vps-stock.json
```

库存状态放在仓库外，不会进入 Git；监控不会登录、下单或修改任何供应商账户。

## English

### Choose one entry point

```bash
# Provision a new Google Cloud node
./deploy-gcp.sh

# Configure an existing Debian/Ubuntu VPS
VPS_PROFILE=frantech VPS_SSH_KEY="$HOME/.ssh/frantech_ed25519" ./deploy-vps.sh <VPS_PUBLIC_IP>
```

Both entry points run the same shared pipeline:

1. Validate provider-specific requirements.
2. Generate per-device credentials locally.
3. Provision or secure a reachable host.
4. Install BBR, Xray/Reality, Hysteria2, AnyTLS, systemd units, and security updates.
5. Recover the Reality public key and generate one Mihomo YAML per device.

The provider adapters only own host lifecycle, connectivity, and firewall behaviour. Key generation, server configuration, routing rules, optional Cloudflare setup, and client generation remain in `core/`.

For a non-default VPS key:

```bash
VPS_PROFILE=<profile> VPS_SSH_KEY=/path/to/private-key ./deploy-vps.sh <VPS_PUBLIC_IP>
```

Never copy private keys or `.secrets.env` into Git-tracked files, onto the server, or into chat.

## License

MIT — see [LICENSE](LICENSE).
