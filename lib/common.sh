# shared helpers — source this file. POSIX-bash 3.2 compatible (macOS default).

KIT_DIR="${KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONF_FILE="$KIT_DIR/deploy.conf"
SECRETS_FILE="$KIT_DIR/.secrets.env"

# --- logging ---
say() { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --- config / secrets loading ---
load_conf()    { if [ -f "$CONF_FILE" ];    then set -a; . "$CONF_FILE";    set +a; fi; return 0; }
load_secrets() { if [ -f "$SECRETS_FILE" ]; then set -a; . "$SECRETS_FILE"; set +a; fi; return 0; }

# secret_get KEY  -> prints current value from .secrets.env (empty if absent)
secret_get() {
  [ -f "$SECRETS_FILE" ] || return 0
  { grep -E "^$1=" "$SECRETS_FILE" || true; } | tail -1 | cut -d= -f2-
}

# setkv KEY VALUE  -> replace-or-add in .secrets.env and export into env
setkv() {
  local k="$1" v="$2" tmp
  touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  tmp="$(mktemp)"
  grep -vE "^$k=" "$SECRETS_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  export "$k=$v"
}

# ensure_secret KEY VALUE  -> set only if currently absent/empty
ensure_secret() {
  local cur; cur="$(secret_get "$1")"
  [ -n "$cur" ] || setkv "$1" "$2"
}

# indirect var read, bash-3.2 safe:  varval NAME
varval() { eval "printf '%s' \"\${$1:-}\""; }
