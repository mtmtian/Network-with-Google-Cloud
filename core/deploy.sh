#!/usr/bin/env bash
# Shared deployment pipeline. Provider adapters implement this interface:
# provider_init, provider_preflight, provider_configure, provider_provision,
# provider_install, provider_print_summary.

build_server_env() {
  local target="$1" k d
  {
    for k in REALITY_PORT REALITY_TARGET REALITY_SNI DEVICES; do
      printf "export %s='%s'\n" "$k" "$(varval "$k")"
    done
    for k in REALITY_SHORTID HY2_PORT ANYTLS_PORT ANYTLS_PASS; do
      printf "export %s='%s'\n" "$k" "$(secret_get "$k")"
    done
    for d in $DEVICES; do
      printf "export REALITY_UUID_%s='%s'\n" "$d" "$(secret_get "REALITY_UUID_$d")"
      printf "export HY2_PASS_%s='%s'\n" "$d" "$(secret_get "HY2_PASS_$d")"
    done
    printf "export CDN_ENABLE='%s'\n" "${CDN_ENABLE:-false}"
    if [ "${CDN_ENABLE:-false}" = "true" ]; then
      printf "export CDN_WS_PATH='%s'\n" "$(secret_get CDN_WS_PATH)"
      printf "export CF_TUNNEL_TOKEN='%s'\n" "$(secret_get CF_TUNNEL_TOKEN)"
      for d in $DEVICES; do
        printf "export CDN_UUID_%s='%s'\n" "$d" "$(secret_get "CDN_UUID_$d")"
      done
    fi
  } > "$target"
  chmod 600 "$target"
}

cleanup_deploy_tmp() {
  [ -z "${DEPLOY_TMP_DIR:-}" ] || rm -rf "$DEPLOY_TMP_DIR"
}

redact_server_output() {
  sed -E 's/^(REALITY_PUBLIC_KEY=).*/\1[redacted]/'
}

run_deploy() {
  printf '\n\033[1;35m=== %s ===\033[0m\n\n' "$PROVIDER_TITLE"

  provider_init "$@"
  provider_preflight
  provider_configure
  load_conf
  REALITY_TARGET="${REALITY_TARGET:-${REALITY_SNI}:443}"
  export REALITY_TARGET
  ok "$PROVIDER_DESCRIPTION  设备=[$DEVICES]"

  PROFILE_NAME="$PROFILE_NAME" \
    NETWORK_NODE_STATE_DIR="$STATE_DIR" \
    bash "$PROJECT_DIR/core/secrets.sh"
  load_secrets

  provider_provision
  load_secrets

  if [ "${CDN_ENABLE:-false}" = "true" ]; then
    bash "$PROJECT_DIR/core/cloudflare.sh"
    load_secrets
  fi

  local srv_env srv_out rc pub
  DEPLOY_TMP_DIR="$(mktemp -d)"
  trap cleanup_deploy_tmp EXIT
  srv_env="$DEPLOY_TMP_DIR/server-env.sh"
  build_server_env "$srv_env"

  say "上传并执行服务端安装脚本（首次通常 2-5 分钟）"
  set +e
  srv_out="$(provider_install "$PROJECT_DIR/core/setup-server.sh" "$PROJECT_DIR/core/download.sh" "$srv_env" 2>&1)"
  rc=$?
  set -e
  echo "$srv_out" | redact_server_output | sed 's/^/    │ /'
  [ "$rc" -eq 0 ] || die "远端安装失败（见上方日志）"

  pub="$(echo "$srv_out" | grep '^REALITY_PUBLIC_KEY=' | tail -1 | cut -d= -f2)"
  [ -n "$pub" ] || die "未能取回 Reality 公钥"
  setkv REALITY_PUBLIC "$pub"

  say "生成 Clash/Mihomo 配置"
    NETWORK_NODE_ROOT="$PROJECT_DIR" \
    NETWORK_NODE_STATE_DIR="$STATE_DIR" \
    NETWORK_NODE_CLIENTS_DIR="$CLIENTS_DIR" \
    NETWORK_NODE_PROFILE="$PROFILE_NAME" \
    python3 "$PROJECT_DIR/core/gen-clash.py"

  printf '\n\033[1;32m=== 部署完成 ===\033[0m\n'
  provider_print_summary
  echo "  Reality   : TCP $REALITY_PORT"
  echo "  Hysteria2 : UDP $HY2_PORT"
  echo "  AnyTLS    : TCP $ANYTLS_PORT"
  if [ "${CDN_ENABLE:-false}" = "true" ]; then
    echo "  CDN       : $CDN_HOSTNAME"
  fi
  echo "  配置文件  : $CLIENTS_DIR/${PROFILE_NAME}-*.yaml"
}
