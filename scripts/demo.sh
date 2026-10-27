#!/usr/bin/env bash
# Guided walkthrough of mTLS authentication + identity-pool authorization.
# Each step states the expected outcome and checks that it happened.
# Runs on the client host inside the VPC; start it with `make demo` (interactive)
# or `make demo-batch` (DEMO_PAUSE=0, output printed when done).
set -uo pipefail
source "$(dirname "$0")/common.sh"

PY="$VENV_DIR/bin/python"
CLIENT="$REPO_ROOT/clients/mtls_client.py"
[[ -x "$PY" ]] || die "virtualenv missing; run make setup"
[[ -f "$DEMO_DIR/bootstrap" ]] || die "cluster not provisioned; run make up"

PAUSE="${DEMO_PAUSE:-$([[ -t 0 ]] && echo 1 || echo 0)}"
PASSED=0; FAILED=0
RUN_ID="$(date +%s)"

pause() { [[ "$PAUSE" == "1" ]] && { printf '%s(press enter)%s' "$C_DIM" "$C_RESET"; read -r _; }; }

banner() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
  shift
  local line; for line in "$@"; do printf '  %s\n' "$line"; done
}

cert_summary() {
  local f="$PKI_OUT/clients/$1/cert.pem" o; o="$(find_openssl)"
  printf '  %scert:%s %s\n' "$C_DIM" "$C_RESET" "$("$o" x509 -in "$f" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
  printf '  %ssan: %s %s\n' "$C_DIM" "$C_RESET" "$("$o" x509 -in "$f" -noout -ext subjectAltName | tail -n1 | sed 's/^ *//')"
  printf '  %sissuer:%s %s\n' "$C_DIM" "$C_RESET" "$("$o" x509 -in "$f" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
}

# expect <allow|deny> <identity> <client args...>
expect() {
  local want="$1" identity="$2"; shift 2
  "$PY" "$CLIENT" --identity "$identity" "$@"
  local rc=$?
  # Exit 1 is a clean denial; anything else non-zero is a usage error or crash.
  if { [[ "$want" == allow && $rc -eq 0 ]] || [[ "$want" == deny && $rc -eq 1 ]]; }; then
    printf '  %s[as expected]%s\n' "$C_GREEN" "$C_RESET"; PASSED=$((PASSED + 1))
  else
    printf '  %s[UNEXPECTED: wanted %s]%s\n' "$C_RED" "$want" "$C_RESET"; FAILED=$((FAILED + 1))
  fi
}

printf '%sConfluent Cloud mTLS demo%s  bootstrap=%s\n' "$C_BOLD" "$C_RESET" "$(cat "$DEMO_DIR/bootstrap")"
printf '%sIdentity pools (CEL filter -> permissions) are defined in terraform/mtls.tf%s\n' "$C_DIM" "$C_RESET"
pause

banner "0. Platform team creates the topics with its certificate (no API key)" \
  "Pool platform-admins: O == \"Acme Corp\" && OU == \"platform\"  ->  DeveloperManage topic=*"
cert_summary platform-admin
expect allow platform-admin create-topics orders fraud-alerts
pause

banner "1. Payments service writes orders" \
  "Pool payments-producers: O == \"Acme Corp\" && OU == \"payments\"  ->  DeveloperWrite topic orders"
cert_summary orders-producer
expect allow orders-producer produce --topic orders --count 3
pause

banner "2. Analytics reads orders" \
  "Pool analytics-readers: OU == \"analytics\"  ->  DeveloperRead topic orders + group analytics-*"
cert_summary analytics-consumer
expect allow analytics-consumer consume --topic orders --group "analytics-dashboard-$RUN_ID" --count 3
pause

banner "3. Least privilege: analytics cannot write" \
  "Authenticated, but the analytics-readers pool has no write role on orders."
expect deny analytics-consumer produce --topic orders --count 1 --timeout 15
pause

banner "4. Least privilege: analytics limited to its own consumer groups" \
  "Group 'payments-audit' does not match the analytics-* prefix."
expect deny analytics-consumer consume --topic orders --group payments-audit --count 1 --timeout 15
pause

banner "5. Workload identity from a SPIFFE URI SAN" \
  "Pool risk-workloads: SAN.contains(\"URI:spiffe://acme.demo/ns/risk/\")" \
  "  ->  DeveloperRead orders, DeveloperWrite fraud-alerts, DeveloperRead group fraud-*"
cert_summary fraud-detector
expect allow fraud-detector consume --topic orders --group "fraud-detector-$RUN_ID" --count 3
expect allow fraud-detector produce --topic fraud-alerts --count 1
pause

banner "6. Trusted CA, but no identity pool matches (OU=marketing)" \
  "The TLS handshake succeeds, but authentication fails because no CEL filter matches." \
  "Confluent Cloud does not tell the client why, so it surfaces as a timeout."
cert_summary marketing-app
expect deny marketing-app list-topics --timeout 15
pause

banner "7. Imposter: identical subject DN, signed by an untrusted CA" \
  "Same O/OU/CN as orders-producer, but the issuing CA was never uploaded to Confluent Cloud."
cert_summary imposter
expect deny imposter list-topics --timeout 15

printf '\n%sResult:%s %d step(s) as expected, %d unexpected\n' "$C_BOLD" "$C_RESET" "$PASSED" "$FAILED"
printf '%sNext: run "make revoke" to show certificate revocation via CRL.%s\n' "$C_DIM" "$C_RESET"
[[ $FAILED -eq 0 ]]
