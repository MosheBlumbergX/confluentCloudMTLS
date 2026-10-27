#!/usr/bin/env bash
# Certificate revocation walkthrough (run from your machine, where the CA lives):
#   1. legacy-producer (OU=payments) can write to orders
#   2. its certificate is revoked in the issuing CA and a new CRL is uploaded
#   3. the same certificate is now rejected; orders-producer still works
#
# The Kafka clients run on the client host inside the VPC (scripts/remote.sh).
# Run scripts/revoke-demo.sh reset afterwards to reissue legacy-producer.
set -uo pipefail
source "$(dirname "$0")/common.sh"
require_ccloud_creds

REMOTE="$REPO_ROOT/scripts/remote.sh"
WAIT_SECONDS="${WAIT_SECONDS:-600}"

client() { "$REMOTE" exec ".venv/bin/python clients/mtls_client.py $*"; }

apply_crl() {
  info "uploading CRL chain to the Confluent Cloud certificate authority"
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false \
    -target=confluent_certificate_authority.acme >/dev/null || die "terraform apply failed"
  ok "CRL uploaded"
}

if [[ "${1:-}" == "reset" ]]; then
  "$REPO_ROOT/scripts/pki.sh" issue legacy-producer
  "$REPO_ROOT/scripts/pki.sh" crl
  apply_crl
  "$REMOTE" sync
  exit 0
fi

"$REMOTE" sync >/dev/null

printf '%s1. legacy-producer before revocation%s\n' "$C_BOLD" "$C_RESET"
client --identity legacy-producer produce --topic orders --count 1 \
  || warn "legacy-producer is already rejected (revoked earlier? run: $0 reset)"

printf '\n%s2. Revoke the certificate and publish the CRL%s\n' "$C_BOLD" "$C_RESET"
"$REPO_ROOT/scripts/pki.sh" revoke legacy-producer || exit 1
apply_crl

printf '\n%s3. legacy-producer after revocation%s\n' "$C_BOLD" "$C_RESET"
info "retrying until the brokers pick up the new CRL (up to ${WAIT_SECONDS}s)"
start=$(date +%s); deadline=$(( start + WAIT_SECONDS ))
while (( $(date +%s) < deadline )); do
  if ! client --identity legacy-producer --timeout 15 produce --topic orders --count 1; then
    ok "revoked certificate rejected after $(( $(date +%s) - start ))s"
    printf '%sorders-producer (same OU, not revoked) still works:%s\n' "$C_DIM" "$C_RESET"
    client --identity orders-producer produce --topic orders --count 1
    exit 0
  fi
  sleep 20
done
die "legacy-producer still accepted after ${WAIT_SECONDS}s"
