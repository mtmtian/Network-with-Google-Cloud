# Troubleshooting Notes

## Node Timeout But Server Is Running

This note records a real failure mode: the client showed proxy node timeouts, while the GCP VM and proxy services were still running normally.

### Symptoms

- The client imports the generated YAML successfully.
- All proxy nodes show timeout during testing.
- Rule providers may still load, or may be unrelated to the failure.
- The VM is running and the proxy ports are reachable from the public Internet.

### Root Cause

The generated client YAML pointed to an outdated IP address in `profiles/gcloud/.secrets.env`:

- `STATIC_IP` in `profiles/gcloud/.secrets.env` had an old value.
- The existing VM had a different current external IP.
- Service credentials and ports were correct, but clients were connecting to the wrong address.

When the client reports the node itself as timeout, check the server address first. Routing rules only decide where traffic goes after a proxy connection exists; they do not normally break the proxy handshake itself.

### Checks

Run these locally after loading the GCloud profile state.

```bash
set -a
. profiles/gcloud/deploy.conf
. profiles/gcloud/.secrets.env
set +a
```

```bash
gcloud --project "$PROJECT_ID" compute instances describe "$INSTANCE_NAME" \
  --zone "$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
```

```bash
grep '^STATIC_IP=' profiles/gcloud/.secrets.env
```

The two IPs must match.

Then confirm the VM and firewall are healthy.

```bash
gcloud --project "$PROJECT_ID" compute instances describe "$INSTANCE_NAME" \
  --zone "$ZONE" \
  --format="yaml(name,status,tags.items,networkInterfaces[0].accessConfigs[0].natIP)"
```

```bash
gcloud --project "$PROJECT_ID" compute firewall-rules list \
  --filter="name=(allow-proxy allow-iap-ssh)" \
  --format="table(name,direction,disabled,sourceRanges.list(),allowed[].map().firewall_rule().list(),targetTags.list())"
```

If you can access the VM over IAP SSH, check systemd services and listeners.

```bash
gcloud --project "$PROJECT_ID" compute ssh "$INSTANCE_NAME" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --command "sudo systemctl is-active xray hysteria anytls; sudo ss -tulnp | grep -E 'xray|hysteria|anytls'"
```

### Fix

1. Update `profiles/gcloud/.secrets.env` so `STATIC_IP` matches the VM external IP.
2. Regenerate GCloud client configs:

```bash
NETWORK_NODE_PROFILE=gcloud python3 core/gen-clash.py
```

3. Re-import the regenerated YAML into the client. Delete the old client profile first if the app caches old proxy entries.

Restarting the VM is not required when only the generated client YAML is wrong. Re-run the same provider entry point or restart services only when the server-side ports, credentials, or service configs changed.

### Prevention

- Treat each `profiles/<provider>/` directory as one local state bundle; keep generated clients in `clash-configs/` with the profile prefix and never mix provider state or `ssh/` files.
- If a static IP is deleted or the VM external IP changes, regenerate client YAML immediately.
- Do not commit profile `.secrets.env`, SSH keys, or generated client YAML; they contain real server details and credentials.

## 中文总结：节点 Timeout 但服务端正常

这次问题不是规则集导致的。客户端显示“节点 timeout”时，优先怀疑节点地址、端口、防火墙、服务状态或协议兼容；规则集只影响连接建立后的分流。

本次根因是本地 `profiles/gcloud/.secrets.env` 里的 `STATIC_IP` 仍是旧地址，而 GCP 上现有 VM 的外部 IP 已变化。服务端 `xray`、`hysteria`、`anytls` 都正常运行，端口也开放，密钥/UUID 与本地配置一致；客户端只是连到了错误地址。

处理方式：

1. 对比 GCP VM 当前外部 IP 和 `profiles/gcloud/.secrets.env` 里的 `STATIC_IP`。
2. 把 `profiles/gcloud/.secrets.env` 更新为当前 VM IP。
3. 运行 `NETWORK_NODE_PROFILE=gcloud python3 core/gen-clash.py`。
4. 在客户端删除旧 profile 后重新导入生成的 YAML。

只修正客户端 YAML 时不需要重启 VM。只有服务端端口、凭据或 systemd 服务配置发生变化时，才需要重跑原平台入口或重启相关服务。

风险点：如果 VM 没有绑定保留静态 IP，重启或重建后外部 IP 可能再次变化。生产使用建议确认静态 IP 存在且绑定到 VM。
