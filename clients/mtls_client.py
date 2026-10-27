#!/usr/bin/env python3
"""Minimal Kafka client that authenticates to Confluent Cloud with mTLS.

Each identity in pki/out/clients/<name>/ has a PKCS12 keystore holding its
private key and certificate chain. There are no API keys and no pool IDs in
the config: Confluent Cloud picks the identity pool(s) whose CEL filter
matches the presented certificate.

Examples:
  mtls_client.py --identity platform-admin create-topics orders fraud-alerts
  mtls_client.py --identity orders-producer produce --topic orders --count 5
  mtls_client.py --identity analytics-consumer consume --topic orders --group analytics-dashboard
  mtls_client.py --identity marketing-app list-topics
"""

import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path

import certifi
from confluent_kafka import Consumer, KafkaError, KafkaException, Producer
from confluent_kafka.admin import AdminClient, NewTopic

REPO_ROOT = Path(__file__).resolve().parent.parent
CLIENTS_DIR = REPO_ROOT / "pki" / "out" / "clients"
BOOTSTRAP_FILE = REPO_ROOT / ".demo" / "bootstrap"

GREEN, RED, DIM, RESET = ("\033[32m", "\033[31m", "\033[2m", "\033[0m") if sys.stdout.isatty() else ("",) * 4


def bootstrap_servers() -> str:
    if os.environ.get("BOOTSTRAP_SERVERS"):
        return os.environ["BOOTSTRAP_SERVERS"]
    if BOOTSTRAP_FILE.exists():
        return BOOTSTRAP_FILE.read_text().strip()
    sys.exit("Bootstrap servers unknown: run `make up` or set BOOTSTRAP_SERVERS.")


def base_config(identity: str, timeout_s: int) -> dict:
    ident_dir = CLIENTS_DIR / identity
    keystore = ident_dir / "keystore.p12"
    if not keystore.exists():
        sys.exit(f"No keystore for identity '{identity}' at {keystore}. Run `make pki`.")

    seen_errors = set()

    def on_error(err: KafkaError) -> None:
        msg = f"{err.name()}: {err.str()}"
        if msg not in seen_errors:
            seen_errors.add(msg)
            print(f"  {DIM}client error  {msg}{RESET}", file=sys.stderr)

    return {
        "bootstrap.servers": bootstrap_servers(),
        "client.id": identity,
        # mTLS: plain SSL, no SASL. The keystore is our credential.
        "security.protocol": "SSL",
        "ssl.keystore.location": str(keystore),
        "ssl.keystore.password": (ident_dir / "keystore.password").read_text().strip(),
        # Confluent Cloud brokers present Let's Encrypt certificates.
        "ssl.ca.location": certifi.where(),
        "socket.timeout.ms": timeout_s * 1000,
        "log_level": 0,
        "error_cb": on_error,
    }


def result(ok: bool, text: str) -> int:
    print(f"{GREEN + 'ALLOWED' if ok else RED + 'DENIED '}{RESET}  {text}")
    return 0 if ok else 1


def cmd_list_topics(args) -> int:
    admin = AdminClient(base_config(args.identity, args.timeout))
    try:
        md = admin.list_topics(timeout=args.timeout)
    except KafkaException as e:
        return result(False, f"{args.identity} could not connect/authenticate: {e.args[0].str()}")
    topics = sorted(t for t in md.topics if not t.startswith("_"))
    return result(True, f"{args.identity} authenticated; visible topics: {topics or '(none)'}")


def cmd_create_topics(args) -> int:
    admin = AdminClient(base_config(args.identity, args.timeout))
    futures = admin.create_topics([NewTopic(t, num_partitions=args.partitions) for t in args.topics],
                                  request_timeout=args.timeout)
    created, existing = [], []
    for topic, fut in futures.items():
        try:
            fut.result()
            created.append(topic)
        except KafkaException as e:
            err = e.args[0]
            if err.code() != KafkaError.TOPIC_ALREADY_EXISTS:
                return result(False, f"{args.identity} could not create '{topic}': {err.name()}")
            existing.append(topic)
    return result(True, f"{args.identity} created {created or 'nothing'}; already existed: {existing or 'none'}")


def cmd_produce(args) -> int:
    conf = base_config(args.identity, args.timeout)
    conf["message.timeout.ms"] = args.timeout * 1000
    producer = Producer(conf)
    delivered, errors = 0, []

    def on_delivery(err, msg):
        nonlocal delivered
        if err:
            errors.append(err)
        else:
            delivered += 1

    for i in range(args.count):
        order = {"order_id": str(uuid.uuid4())[:8], "amount": round(10 + i * 7.5, 2), "producer": args.identity}
        producer.produce(args.topic, key=order["order_id"], value=json.dumps(order), on_delivery=on_delivery)
        producer.poll(0)
    producer.flush(args.timeout + 5)

    if delivered == args.count:
        return result(True, f"{args.identity} produced {delivered} message(s) to '{args.topic}'")
    reason = errors[0].name() if errors else "timed out (no delivery report)"
    return result(False, f"{args.identity} could not produce to '{args.topic}': {reason}")


def cmd_consume(args) -> int:
    conf = base_config(args.identity, args.timeout)
    conf.update({"group.id": args.group, "auto.offset.reset": "earliest", "enable.auto.commit": True})
    consumer = Consumer(conf)
    consumer.subscribe([args.topic])
    received, deadline = 0, time.time() + args.timeout
    try:
        while received < args.count and time.time() < deadline:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                return result(False, f"{args.identity} could not consume '{args.topic}' as group '{args.group}': {msg.error().name()}")
            received += 1
            print(f"  {DIM}p{msg.partition()}@{msg.offset()} {msg.value().decode()}{RESET}")
    finally:
        consumer.close()
    if received:
        return result(True, f"{args.identity} consumed {received} message(s) from '{args.topic}' as group '{args.group}'")
    return result(False, f"{args.identity} received nothing from '{args.topic}' within {args.timeout}s")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--identity", required=True, help="client identity under pki/out/clients/")
    p.add_argument("--timeout", type=int, default=20, help="seconds before giving up (default 20)")
    # Also accept --timeout after the subcommand.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--timeout", type=int, default=argparse.SUPPRESS, help=argparse.SUPPRESS)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list-topics", parents=[common], help="connect and list visible topics")

    st = sub.add_parser("create-topics", parents=[common], help="create topics (idempotent)")
    st.add_argument("topics", nargs="+")
    st.add_argument("--partitions", type=int, default=3)

    sp = sub.add_parser("produce", parents=[common], help="produce sample orders")
    sp.add_argument("--topic", default="orders")
    sp.add_argument("--count", type=int, default=3)

    sc = sub.add_parser("consume", parents=[common], help="consume messages")
    sc.add_argument("--topic", default="orders")
    sc.add_argument("--group", required=True)
    sc.add_argument("--count", type=int, default=3)

    args = p.parse_args()
    return {"list-topics": cmd_list_topics, "create-topics": cmd_create_topics, "produce": cmd_produce, "consume": cmd_consume}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
