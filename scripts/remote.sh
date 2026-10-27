#!/usr/bin/env bash
# Drive the client host inside the demo VPC through AWS SSM. Enterprise
# clusters are reachable only over PrivateLink, so the Kafka clients run there.
#
# Usage:
#   scripts/remote.sh wait          wait until the host is online and bootstrapped
#   scripts/remote.sh sync          push scripts + client keystores to the host
#   scripts/remote.sh run <cmd>     sync, then run <cmd> in /opt/mtls-demo, print output
#   scripts/remote.sh exec <cmd>    like run, without syncing first
#   scripts/remote.sh tty <cmd>     sync, then run <cmd> interactively (needs session-manager-plugin)
#   scripts/remote.sh shell         interactive root shell in /opt/mtls-demo
#
# Only client keystores and certificates are synced; CA private keys stay local.
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_env

REMOTE_DIR=/opt/mtls-demo
[[ -f "$DEMO_DIR/remote.env" ]] || die "no client host recorded; run make up"
# shellcheck disable=SC1091
source "$DEMO_DIR/remote.env"   # INSTANCE_ID, BUNDLE_BUCKET, AWS_REGION
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

# Run a shell command on the host as root; stream its output back; return its exit code.
ssm_exec() {
  local cmd="$1" cid status
  cid="$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
    --comment "mtls-demo" --parameters "$(jq -cn --arg c "$cmd" '{commands: [$c]}')" \
    --query Command.CommandId --output text)"
  while :; do
    sleep 2
    status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" \
      --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in Pending|InProgress|Delayed) ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" --output json \
    | jq -r '.StandardOutputContent, (.StandardErrorContent | select(length > 0))' \
    | grep -v '^failed to run commands: exit status' || true
  [[ "$status" == "Success" ]]
}

sync_bundle() {
  local bundle="$DEMO_DIR/bundle.tgz"
  COPYFILE_DISABLE=1 tar --no-xattrs -czf "$bundle" -C "$REPO_ROOT" \
    --exclude 'key.pem' --exclude 'req.csr' --exclude '__pycache__' \
    clients scripts pki/openssl.cnf pki/identities.txt pki/out/clients pki/out/ca-chain.pem .demo/bootstrap
  aws s3 cp --quiet "$bundle" "s3://$BUNDLE_BUCKET/bundle.tgz"
}

remote_prefix() {
  echo "aws s3 cp --quiet --region $AWS_REGION s3://$BUNDLE_BUCKET/bundle.tgz /tmp/bundle.tgz \
&& rm -rf $REMOTE_DIR/pki/out/clients && tar -xzf /tmp/bundle.tgz -C $REMOTE_DIR"
}

interactive() {
  command -v session-manager-plugin >/dev/null \
    || die "session-manager-plugin is required for interactive sessions: brew install --cask session-manager-plugin (or use: $0 run <cmd>)"
  aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartInteractiveCommand \
    --parameters "$(jq -cn --arg c "sudo bash -c 'cd $REMOTE_DIR && $1'" '{command: [$c]}')"
}

cmd_wait() {
  info "waiting for client host $INSTANCE_ID to register with SSM"
  local i
  for i in $(seq 1 60); do
    [[ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" == "Online" ]] && break
    sleep 10
  done
  info "waiting for client host bootstrap (python deps, Kafka CLI)"
  for i in $(seq 1 60); do
    ssm_exec "test -f $REMOTE_DIR/.ready" >/dev/null 2>&1 && { ok "client host ready"; return; }
    sleep 10
  done
  die "client host not ready after 10 minutes; check /var/log/cloud-init-output.log via: $0 shell"
}

case "${1:-}" in
  wait)  cmd_wait ;;
  sync)  sync_bundle && ssm_exec "$(remote_prefix)" >/dev/null && ok "synced to $INSTANCE_ID" ;;
  run)   shift; sync_bundle; ssm_exec "$(remote_prefix) && cd $REMOTE_DIR && $*" ;;
  exec)  shift; ssm_exec "cd $REMOTE_DIR && $*" ;;
  tty)   shift; sync_bundle; ssm_exec "$(remote_prefix)" >/dev/null; interactive "$*" ;;
  shell) interactive "exec bash -l" ;;
  *)     sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
