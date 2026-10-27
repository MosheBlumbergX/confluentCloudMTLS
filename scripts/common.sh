# Shared helpers, sourced by the other scripts.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI_DIR="$REPO_ROOT/pki"
PKI_OUT="$PKI_DIR/out"
TF_DIR="$REPO_ROOT/terraform"
DEMO_DIR="$REPO_ROOT/.demo"
VENV_DIR="$REPO_ROOT/.venv"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

info()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()    { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Load Confluent Cloud credentials from .env if present.
load_env() {
  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
  fi
  # An empty AWS_PROFILE= line in .env would otherwise mask other credential sources.
  [[ -n "${AWS_PROFILE:-}" ]] || unset AWS_PROFILE
}

require_ccloud_creds() {
  load_env
  [[ -n "${CONFLUENT_CLOUD_API_KEY:-}" && -n "${CONFLUENT_CLOUD_API_SECRET:-}" ]] \
    || die "CONFLUENT_CLOUD_API_KEY / CONFLUENT_CLOUD_API_SECRET not set. Copy .env.example to .env and fill it in."
}

# Prefer a real OpenSSL 3 over macOS LibreSSL.
find_openssl() {
  if [[ -n "${OPENSSL_BIN:-}" ]]; then echo "$OPENSSL_BIN"; return; fi
  local c
  for c in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl)"; do
    if [[ -x "$c" ]] && "$c" version | grep -q '^OpenSSL 3'; then echo "$c"; return; fi
  done
  die "OpenSSL 3.x not found (macOS ships LibreSSL). Install it: brew install openssl@3, or set OPENSSL_BIN."
}
