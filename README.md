# Network with Google Cloud

One command to spin up your own US proxy node on **your own GCP account**, auto-install the server, and generate ready-to-import **Clash Verge** configs.

一条命令在**你自己的 GCP 账号**上开好一台美国代理节点，自动安装服务端，并生成可直接导入 **Clash Verge** 的配置。

**Language / 语言:** [English](#english) · [中文](#中文)

- **Protocols / 协议**: VLESS + Reality (primary) + Hysteria2 (UDP fallback) + AnyTLS (TCP fallback). Reality is used by default.
- **Machine / 机型**: `e2-micro` — covered by GCP Free Tier for 24/7 running; you only pay for egress traffic.
- **Multi-device / 多设备**: every device gets its own keys, so a leaked device can be revoked alone.

---

<a name="english"></a>
# English

## 1. What this does

Running `./deploy.sh` once will, end to end:

1. **Preflight** — check that `gcloud` / `python3` / `openssl` are installed and you are logged in.
2. **Generate keys locally** — Reality UUIDs, Hysteria2 per-device passwords, AnyTLS password, short-id.
3. **Provision GCP** (idempotent) — reserve a static IP → firewall rules → create the `e2-micro` VM.
4. **Install the server** over IAP SSH — BBR + Xray (VLESS+Reality) + Hysteria2 + AnyTLS + systemd + SSH hardening.
5. **Generate configs** — one `clash-configs/<device>.yaml` per device.

Re-running is safe: existing cloud resources are reused, only the configs are refreshed.

## 2. Prerequisites (one time)

1. **A GCP account with billing enabled** (this uses *your* quota / spend).
2. **Install and log into the gcloud CLI:**
   ```bash
   # Install: https://cloud.google.com/sdk/docs/install
   gcloud auth login
   gcloud config set project <YOUR_PROJECT_ID>   # create a project in the console first if needed
   ```
3. `python3` and `openssl` on your machine (built in on most macOS / Linux).

> The scripts only run on your machine and your own cloud. Nothing is uploaded to any third party.

## 3. Run

```bash
git clone https://github.com/oratis/Network-with-Google-Cloud.git
cd Network-with-Google-Cloud
./deploy.sh
```

On first run it asks a few questions (project ID / region / device list), then does everything automatically. Takes ~15 minutes.

## 4. Import into Clash Verge

- **Desktop Clash Verge**: Settings → Profiles → Import → pick the `.yaml` for your device under `clash-configs/`.
- **Phone**: use a Mihomo / Clash.Meta compatible client with Reality, Hysteria2, and AnyTLS support, then import the matching `.yaml`.

Each device uses its own file — same server / port, but independent keys.

## 5. Configuration

`deploy.conf` is generated on first run (edit it and re-run to change things):

| Key | Default | Meaning |
|---|---|---|
| `PROJECT_ID` | — | Your GCP project |
| `REGION` / `ZONE` | `us-west1` / `us-west1-a` | Free Tier regions: `us-west1` / `us-central1` / `us-east1` |
| `MACHINE_TYPE` | `e2-micro` | Free Tier machine type |
| `NETWORK_TIER` | `PREMIUM` | Google backbone (more stable trans-Pacific); switch to `STANDARD` to save on heavy traffic |
| `REALITY_PORT` / `REALITY_SNI` | `443` / `www.microsoft.com` | Reality port and camouflage domain |
| `HY2_PORT` | random | Hysteria2 UDP fallback port; leave blank to auto-pick a random high port |
| `ANYTLS_PORT` | random | AnyTLS TCP fallback port; leave blank to auto-pick a random high port |
| `DEVICES` | `mac iphone ipad laptop spare` | Device names to generate configs for; add/remove freely |

## 6. Add / revoke devices

Edit `DEVICES` in `deploy.conf` and re-run `./deploy.sh`:

- **Add a device** → new keys are generated, pushed to the server, and a new YAML is produced.
- **Revoke a device** → remove its name; after re-running, the server stops accepting its keys and the old config dies.

## 7. Cost

- VM / 30GB disk / static IP (while attached to a running VM): covered by Free Tier, essentially **$0**.
- Egress traffic is metered (Premium ≈ $0.085–0.23/GB depending on destination).
- Set a budget alert in GCP Billing.

## 8. Security

- `.secrets.env`, `deploy.conf`, and `clash-configs/` are **gitignored** — they hold your real credentials. **Never commit or forward them.**
- Rotate the IP: delete and re-reserve the static IP (`gcloud compute addresses delete <IP_NAME>`).
- The server has SSH password login disabled and automatic security updates enabled.

## 9. Uninstall

```bash
gcloud compute instances delete <INSTANCE_NAME> --zone <ZONE>
gcloud compute addresses delete <IP_NAME> --region <REGION>
gcloud compute firewall-rules delete allow-proxy allow-iap-ssh
```
(Names are in your `deploy.conf`.)

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `gcloud not logged in` | `gcloud auth login` |
| SSH not ready / scp retries | The VM was just created; wait a moment, the script retries 3×. Re-run `./deploy.sh` if it still fails. |
| No Reality public key returned | The server install failed — check the inlined log above the error for the failing step. |
| Can connect but no US exit | In Clash, make sure the `🚀 Proxy` group points at `US-Reality` or `⚡ Auto`. |
| Reality blocked | Try a different `REALITY_SNI` (any real, reachable foreign HTTPS site) and re-run. |

---

<a name="中文"></a>
# 中文

## 一、它做了什么

运行一次 `./deploy.sh`，端到端完成：

1. **预检** —— 检查 `gcloud` / `python3` / `openssl` 是否安装、是否已登录。
2. **本地生成密钥** —— Reality UUID、Hysteria2 每设备密码、AnyTLS 密码、short-id。
3. **开通 GCP 资源**（幂等）—— 预留静态 IP → 防火墙规则 → 创建 `e2-micro` VM。
4. **远程安装服务端**（经 IAP SSH）—— BBR + Xray（VLESS+Reality）+ Hysteria2 + AnyTLS + systemd + SSH 加固。
5. **生成配置** —— 每台设备一份 `clash-configs/<设备>.yaml`。

重复运行安全：已存在的云资源会复用，只刷新配置。

## 二、准备（只需一次）

1. **一个已绑定结算账户的 GCP 账号**（使用的是*你自己的*额度/费用）。
2. **安装并登录 gcloud CLI：**
   ```bash
   # 安装：https://cloud.google.com/sdk/docs/install
   gcloud auth login
   gcloud config set project <你的项目ID>   # 没有项目就先在控制台建一个
   ```
3. 本机有 `python3` 和 `openssl`（macOS / Linux 基本自带）。

> 脚本只在你本机和你自己的云上运行，不会上传任何内容到第三方。

## 三、运行

```bash
git clone https://github.com/oratis/Network-with-Google-Cloud.git
cd Network-with-Google-Cloud
./deploy.sh
```

首次运行会问几个问题（项目 ID / 区域 / 设备列表），之后全自动完成，约 15 分钟。

## 四、导入 Clash Verge

- **桌面 Clash Verge**：设置 → 配置 → 导入 → 选 `clash-configs/` 里对应设备的 `.yaml`。
- **手机**：使用支持 Reality、Hysteria2、AnyTLS 的 Mihomo / Clash.Meta 兼容客户端，再导入对应 `.yaml`。

每台设备用各自的文件——server / 端口相同，但密钥独立。

## 五、配置说明

`deploy.conf` 首次运行自动生成（改完重跑即可生效）：

| 项 | 默认 | 说明 |
|---|---|---|
| `PROJECT_ID` | — | 你的 GCP 项目 |
| `REGION` / `ZONE` | `us-west1` / `us-west1-a` | Free Tier 免费区：`us-west1` / `us-central1` / `us-east1` |
| `MACHINE_TYPE` | `e2-micro` | Free Tier 机型 |
| `NETWORK_TIER` | `PREMIUM` | 走 Google 骨干，跨洋更稳；流量大可改 `STANDARD` 省钱 |
| `REALITY_PORT` / `REALITY_SNI` | `443` / `www.microsoft.com` | Reality 端口与伪装域名 |
| `HY2_PORT` | 随机 | Hysteria2 UDP 兜底端口，留空自动随机高位端口 |
| `ANYTLS_PORT` | 随机 | AnyTLS TCP 兜底端口，留空自动随机高位端口 |
| `DEVICES` | `mac iphone ipad laptop spare` | 要生成配置的设备名，可增删 |

## 六、增删 / 作废设备

改 `deploy.conf` 的 `DEVICES` 后重跑 `./deploy.sh`：

- **加设备** → 自动生成新密钥、下发到服务端、生成新 YAML。
- **作废设备** → 删掉名字；重跑后服务端不再接受它的密钥，旧配置失效。

## 七、成本

- VM / 30GB 盘 / 静态 IP（挂在运行中的 VM 上）：Free Tier 覆盖，基本 **$0**。
- 出站流量按量计费（Premium 约 $0.085–0.23/GB，取决于目的地）。
- 建议在 GCP Billing 设预算告警。

## 八、安全说明

- `.secrets.env`、`deploy.conf`、`clash-configs/` 均已 **gitignore**，含你的真实凭据，**切勿提交或转发**。
- 想换 IP：删掉静态 IP 重新预留（`gcloud compute addresses delete <IP_NAME>`）。
- 服务端已禁用 SSH 密码登录、开启自动安全更新。

## 九、卸载

```bash
gcloud compute instances delete <INSTANCE_NAME> --zone <ZONE>
gcloud compute addresses delete <IP_NAME> --region <REGION>
gcloud compute firewall-rules delete allow-proxy allow-iap-ssh
```
（名字见你的 `deploy.conf`。）

## 十、排障

| 现象 | 处理 |
|---|---|
| `gcloud 未登录` | `gcloud auth login` |
| SSH 未就绪 / scp 重试 | VM 刚建好，稍等，脚本会重试 3 次；仍失败就重跑 `./deploy.sh`。 |
| 没取回 Reality 公钥 | 服务端安装失败——看错误上方内嵌日志定位失败步骤。 |
| 能连但出口不在美国 | 在 Clash 里把 `🚀 Proxy` 组指向 `US-Reality` 或 `⚡ Auto`。 |
| Reality 被封 | 换一个 `REALITY_SNI`（任意一个真实可达的海外 HTTPS 站点）后重跑。 |

---

## License

MIT — see [LICENSE](LICENSE).
