#!/usr/bin/env bash
# Verify the tools and credentials the demo needs.
set -uo pipefail
source "$(dirname "$0")/common.sh"

missing=0
need() {
  if command -v "$1" >/dev/null 2>&1; then ok "$1 found"; else warn "$1 not found: $2"; missing=1; fi
}

need terraform "https://developer.hashicorp.com/terraform/install"
need aws       "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
need jq        "brew install jq"
command -v session-manager-plugin >/dev/null 2>&1 && ok "session-manager-plugin found" \
  || warn "session-manager-plugin not found: needed for 'make demo' and 'make shell' (brew install --cask session-manager-plugin). 'make demo-batch' works without it."
command -v confluent >/dev/null 2>&1 && ok "confluent CLI found (optional)" \
  || warn "confluent CLI not found (optional, handy for inspecting resources)"

if o="$(find_openssl 2>/dev/null)"; then ok "openssl: $("$o" version)"; else warn "OpenSSL 3 not found: brew install openssl@3"; missing=1; fi

load_env
if [[ -n "${CONFLUENT_CLOUD_API_KEY:-}" && -n "${CONFLUENT_CLOUD_API_SECRET:-}" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' -u "$CONFLUENT_CLOUD_API_KEY:$CONFLUENT_CLOUD_API_SECRET" \
    https://api.confluent.cloud/iam/v2/certificate-authorities)"
  if [[ "$code" == "200" ]]; then ok "Confluent Cloud API key can manage certificate authorities"
  else warn "Confluent Cloud API key check returned HTTP $code (needs an OrganizationAdmin Cloud API key)"; missing=1; fi
else
  warn "CONFLUENT_CLOUD_API_KEY / CONFLUENT_CLOUD_API_SECRET not set (copy .env.example to .env)"; missing=1
fi

if ident="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
  ok "AWS credentials: $ident"
else
  warn "AWS credentials not available (set AWS_PROFILE in .env or export credentials)"; missing=1
fi

exit "$missing"
