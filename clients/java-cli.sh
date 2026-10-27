#!/usr/bin/env bash
# Run the Java Kafka CLI tools (kafka-topics, kafka-console-producer, ...)
# with an identity's certificate. Uses /opt/kafka on the client host, or
# Docker elsewhere.
#
# Usage:
#   clients/java-cli.sh <identity> <tool> [tool args...]
# Examples:
#   clients/java-cli.sh orders-producer kafka-topics --list
#   clients/java-cli.sh analytics-consumer kafka-console-consumer --topic orders \
#       --group analytics-cli --from-beginning --max-messages 3
#
# --bootstrap-server and --command-config/--producer.config/--consumer.config
# are added automatically.
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"

[[ $# -ge 2 ]] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
identity="$1"; tool="$2"; shift 2

ident_dir="$PKI_OUT/clients/$identity"
[[ -f "$ident_dir/keystore.p12" ]] || die "no keystore for '$identity'; run make pki"
[[ -f "$DEMO_DIR/bootstrap" ]] || die "bootstrap unknown; run make up"
bootstrap="$(cat "$DEMO_DIR/bootstrap")"
password="$(cat "$ident_dir/keystore.password")"

case "$tool" in
  kafka-console-producer) cfg_flag="--producer.config" ;;
  kafka-console-consumer) cfg_flag="--consumer.config" ;;
  *)                      cfg_flag="--command-config" ;;
esac

# The documented Java client config for mTLS on Confluent Cloud. The JVM's
# default truststore already trusts the brokers' Let's Encrypt certificates.
write_props() { # keystore-path
  cat <<EOF
security.protocol=SSL
ssl.keystore.location=$1
ssl.keystore.type=PKCS12
ssl.keystore.password=$password
ssl.key.password=$password
EOF
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

if [[ -x /opt/kafka/bin/kafka-topics.sh ]]; then
  write_props "$ident_dir/keystore.p12" > "$tmp/client.properties"
  KAFKA_HEAP_OPTS="-Xmx256m" /opt/kafka/bin/"$tool".sh \
    --bootstrap-server "$bootstrap" "$cfg_flag" "$tmp/client.properties" "$@"
else
  write_props /certs/keystore.p12 > "$tmp/client.properties"
  docker run --rm -i \
    -v "$ident_dir/keystore.p12:/certs/keystore.p12:ro" \
    -v "$tmp/client.properties:/certs/client.properties:ro" \
    --entrypoint "$tool" "${KAFKA_IMAGE:-confluentinc/cp-kafka:7.9.0}" \
    --bootstrap-server "$bootstrap" "$cfg_flag" /certs/client.properties "$@"
fi
