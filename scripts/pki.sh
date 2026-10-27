#!/usr/bin/env bash
# Demo PKI: a private root CA, an intermediate (issuing) CA, a separate
# untrusted "rogue" CA, and client certificates packaged as PKCS12 keystores.
#
# Usage:
#   scripts/pki.sh init            create CAs, issue every identity, build CRL
#   scripts/pki.sh issue <name>    (re)issue one identity from pki/identities.txt
#   scripts/pki.sh revoke <name>   revoke an identity and rebuild the CRL
#   scripts/pki.sh crl             rebuild the CRL chain
#   scripts/pki.sh show <name>     print the subject/SAN/issuer of an identity
#   scripts/pki.sh clean           delete all generated PKI material
set -euo pipefail
source "$(dirname "$0")/common.sh"

OPENSSL="$(find_openssl)"
CNF="$PKI_DIR/openssl.cnf"
IDENTITIES="$PKI_DIR/identities.txt"
ROOT="$PKI_OUT/root"
INTER="$PKI_OUT/intermediate"
ROGUE="$PKI_OUT/rogue"
CLIENTS="$PKI_OUT/clients"
export CLIENT_SAN="DNS:unused"

ssl() { "$OPENSSL" "$@"; }

init_ca_dir() {
  mkdir -p "$1/newcerts"
  chmod 700 "$1"
  touch "$1/index.txt"
  [[ -f "$1/serial" ]] || ssl rand -hex 16 > "$1/serial"
  [[ -f "$1/crlnumber" ]] || echo 1000 > "$1/crlnumber"
}

create_root() { # dir subject
  local dir="$1" subj="$2"
  [[ -f "$dir/ca.crt" ]] && return
  init_ca_dir "$dir"
  ssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/ca.key" 2>/dev/null
  CA_DIR="$dir" ssl req -config "$CNF" -new -x509 -key "$dir/ca.key" -days 3650 \
    -subj "$subj" -extensions v3_root_ca -out "$dir/ca.crt"
  ok "root CA created: $subj"
}

create_intermediate() {
  [[ -f "$INTER/ca.crt" ]] && return
  init_ca_dir "$INTER"
  ssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$INTER/ca.key" 2>/dev/null
  CA_DIR="$INTER" ssl req -config "$CNF" -new -key "$INTER/ca.key" \
    -subj "/C=US/O=Acme Corp/OU=Platform Security/CN=Acme Kafka Issuing CA" -out "$INTER/ca.csr"
  CA_DIR="$ROOT" ssl ca -config "$CNF" -batch -notext -days 1825 \
    -extensions v3_intermediate_ca -in "$INTER/ca.csr" -out "$INTER/ca.crt" 2>/dev/null
  ok "intermediate CA created and signed by root"
}

# The chain uploaded to Confluent Cloud: issuing CA first, then root.
# librdkafka clients need the issuing certificate present in this chain.
build_chain() {
  cat "$INTER/ca.crt" "$ROOT/ca.crt" > "$PKI_OUT/ca-chain.pem"
  ok "CA chain written: pki/out/ca-chain.pem"
}

lookup_identity() { # name -> "issuer|subject|san"
  awk -F'|' -v n="$1" '
    /^[[:space:]]*#/ || NF < 4 { next }
    { for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
    $1 == n { print $2 "|" $3 "|" $4; found = 1 }
    END { exit !found }' "$IDENTITIES"
}

issue() { # name
  local name="$1" spec issuer subj san ca_dir dir pass
  spec="$(lookup_identity "$name")" || die "identity '$name' not found in pki/identities.txt"
  IFS='|' read -r issuer subj san <<< "$spec"
  case "$issuer" in
    trusted) ca_dir="$INTER" ;;
    rogue)   ca_dir="$ROGUE" ;;
    *) die "unknown issuer '$issuer' for $name" ;;
  esac

  dir="$CLIENTS/$name"
  rm -rf "$dir"; mkdir -p "$dir"; chmod 700 "$dir"
  ssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/key.pem" 2>/dev/null
  CA_DIR="$ca_dir" ssl req -config "$CNF" -new -key "$dir/key.pem" -subj "$subj" -out "$dir/req.csr"
  CA_DIR="$ca_dir" CLIENT_SAN="$san" ssl ca -config "$CNF" -batch -notext -days 30 \
    -extensions v3_client -in "$dir/req.csr" -out "$dir/cert.pem" 2>/dev/null

  if [[ "$issuer" == "trusted" ]]; then
    cat "$dir/cert.pem" "$INTER/ca.crt" > "$dir/chain.pem"
  else
    cat "$dir/cert.pem" "$ca_dir/ca.crt" > "$dir/chain.pem"
  fi

  pass="$(ssl rand -hex 12)"
  printf '%s' "$pass" > "$dir/keystore.password"
  ssl pkcs12 -export -name "$name" -inkey "$dir/key.pem" -in "$dir/chain.pem" \
    -passout "pass:$pass" -out "$dir/keystore.p12"
  chmod 600 "$dir"/*
  ok "issued $name ($issuer CA): $subj  [$san]"
}

build_crl() {
  CA_DIR="$INTER" ssl ca -config "$CNF" -gencrl -crlexts crl_ext -out "$INTER/crl.pem" 2>/dev/null
  CA_DIR="$ROOT"  ssl ca -config "$CNF" -gencrl -crlexts crl_ext -out "$ROOT/crl.pem" 2>/dev/null
  cat "$INTER/crl.pem" "$ROOT/crl.pem" > "$PKI_OUT/crl-chain.pem"
  local revoked
  revoked="$(grep -c '^R' "$INTER/index.txt" || true)"
  ok "CRL chain written: pki/out/crl-chain.pem ($revoked revoked client cert(s))"
}

revoke() { # name
  local cert="$CLIENTS/$1/cert.pem"
  [[ -f "$cert" ]] || die "no certificate for '$1'"
  CA_DIR="$INTER" ssl ca -config "$CNF" -revoke "$cert" -crl_reason keyCompromise 2>/dev/null \
    || die "revocation failed (already revoked, or not issued by the trusted CA?)"
  ok "revoked $1 (serial $(ssl x509 -in "$cert" -noout -serial | cut -d= -f2))"
  build_crl
}

show() {
  local cert="$CLIENTS/$1/cert.pem"
  [[ -f "$cert" ]] || die "no certificate for '$1'"
  ssl x509 -in "$cert" -noout -subject -issuer -serial -enddate -ext subjectAltName,extendedKeyUsage
}

cmd_init() {
  mkdir -p "$PKI_OUT" "$CLIENTS"
  create_root "$ROOT"  "/C=US/O=Acme Corp/OU=Platform Security/CN=Acme Root CA"
  create_intermediate
  create_root "$ROGUE" "/C=US/O=Acme Corp/OU=Platform Security/CN=Acme Root CA"
  build_chain
  local name
  for name in $(awk -F'|' '!/^[[:space:]]*#/ && NF >= 4 { gsub(/[[:space:]]/, "", $1); print $1 }' "$IDENTITIES"); do
    # Idempotent: keep existing certs so a re-run does not undo a revocation.
    [[ -f "$CLIENTS/$name/keystore.p12" ]] || issue "$name"
  done
  [[ -f "$PKI_OUT/crl-chain.pem" ]] || build_crl
}

case "${1:-}" in
  init)   cmd_init ;;
  issue)  [[ -n "${2:-}" ]] || die "usage: $0 issue <name>"; issue "$2" ;;
  revoke) [[ -n "${2:-}" ]] || die "usage: $0 revoke <name>"; revoke "$2" ;;
  crl)    build_crl ;;
  show)   [[ -n "${2:-}" ]] || die "usage: $0 show <name>"; show "$2" ;;
  clean)  rm -rf "$PKI_OUT"; ok "removed pki/out" ;;
  *)      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
