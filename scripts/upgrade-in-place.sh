#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Upgrade a SINGLE-NODE Sui stack to a new sui-node release in place, over SSM,
# without the stop/start a `cdk deploy` causes (which wipes the instance store
# and re-bootstraps the node for hours). See ADR-0022.
#
#   scripts/upgrade-in-place.sh --instance-id i-0123... --version v1.84.0 [--region us-east-1]
#                               [--yes] [--dry-run] [--allow-downgrade]
#
# What it does:
#   1. Refuses HA instances (Auto Scaling group); use a rolling `cdk deploy`.
#   2. Reads the node's network and installed release over SSM.
#   3. Checks that <network>-<version> is published with SHA-256 digests for
#      both architectures, and that it is newer than the installed release
#      (unless --allow-downgrade).
#   4. Shows the plan and asks for confirmation (skip with --yes).
#   5. On the instance: runs the blueprint's own installer (same checksum
#      verification as a deploy), restarts node.service, and waits up to 20
#      minutes for /health?threshold_seconds=120 to return 200.
#
# Afterwards the stack still names the old version. The installer's
# never-downgrade safeguard keeps the newer release if setup re-runs (stop/start,
# host maintenance); bump CLIENT_CONFIG (scripts/bump.sh) and `cdk deploy` at the
# next planned window so the stack matches the node again.
#
# Needs: AWS CLI v2 with ssm:SendCommand, ssm:GetCommandInvocation and
# ec2:DescribeInstances for the instance; curl and jq.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/release-lib.sh
. scripts/release-lib.sh

INSTANCE_ID=""; VERSION=""; REGION="${AWS_REGION:-}"; YES=false; DRY_RUN=false; ALLOW_DOWNGRADE=false
usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
    case "$1" in
        --instance-id) INSTANCE_ID="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --region) REGION="${2:-}"; shift 2 ;;
        --yes) YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --allow-downgrade) ALLOW_DOWNGRADE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument '$1' (see --help)" ;;
    esac
done

printf '%s\n' "$INSTANCE_ID" | grep -Eq '^i-[0-9a-f]{8,17}$' || die "--instance-id must look like i-0123456789abcdef0"
printf '%s\n' "$VERSION" | grep -Eq "$VERSION_RE" || die "--version must look like v1.84.0"
command -v aws >/dev/null 2>&1 || die "AWS CLI not found"
[ -n "$REGION" ] || REGION="$(aws configure get region 2>/dev/null || true)"
[ -n "$REGION" ] || die "no region: pass --region or set AWS_REGION"

# Run a POSIX sh script on the instance as root and print its output.
# AWS-RunShellScript runs the commands with /bin/sh (dash on Ubuntu).
ssm_run() {
    local script="$1" timeout="$2" params cmd_id status i
    params="$(jq -n --arg s "$script" --arg t "$timeout" '{commands: [$s], executionTimeout: [$t]}')"
    cmd_id="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript --comment "sui upgrade-in-place" \
        --parameters "$params" --query 'Command.CommandId' --output text)"
    for ((i = 0; i < timeout / 5 + 60; i++)); do
        sleep 5
        status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
            --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
        case "$status" in Pending|InProgress|Delayed) continue ;; esac
        aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
            --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text
        if [ "$status" != "Success" ]; then
            aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
                --instance-id "$INSTANCE_ID" --query StandardErrorContent --output text >&2
            die "command $cmd_id finished with status $status"
        fi
        return 0
    done
    die "timed out waiting for command $cmd_id"
}

# 1. HA guard.
asg="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].Tags[?Key=='aws:autoscaling:groupName'].Value | [0]" --output text)"
if [ -n "$asg" ] && [ "$asg" != "None" ]; then
    die "$INSTANCE_ID belongs to Auto Scaling group $asg (HA). Upgrade HA stacks with scripts/bump.sh and a rolling 'cdk deploy'; an in-place upgrade would be undone by the next replacement"
fi

# 2. Node status.
echo "Reading node status over SSM..."
# shellcheck disable=SC2016  # single-quoted on purpose: expands on the instance, not here
status_out="$(ssm_run '. /etc/cdk_environment
echo "PROTOCOL=${BLOCKCHAIN_PROTOCOL:-}"
echo "MODE=${DEPLOYMENT_MODE:-}"
echo "NETWORK=${BC_NETWORK:-}"
echo "MARKER=$(cat /home/bcuser/bin/.sui-release 2>/dev/null || true)"
echo "SERVICE=$(systemctl is-active node 2>/dev/null || true)"' 120)"
field() { printf '%s\n' "$status_out" | sed -n "s/^$1=//p" | head -1; }
protocol="$(field PROTOCOL)"; mode="$(field MODE)"; network="$(field NETWORK)"; marker="$(field MARKER)"; service="$(field SERVICE)"
[ "$protocol" = "sui" ] || die "instance runs protocol '$protocol', not sui"
[ "$mode" = "single-node" ] || die "instance deployment mode is '$mode'; in-place upgrades are for single-node stacks only"
case "$network" in mainnet|testnet) ;; *) die "unexpected network '$network'" ;; esac
installed="$(printf '%s\n' "$marker" | sed -nE "s/^sui-$network-(v[0-9]+\.[0-9]+\.[0-9]+)-ubuntu-.*\.tgz$/\1/p")"
[ -n "$installed" ] || die "cannot read the installed release from marker '$marker'"

# 3. Release and direction checks.
[ "$installed" != "$VERSION" ] || die "$network-$VERSION is already installed"
if [ "$(newer_version "$installed" "$VERSION")" = "$installed" ] && [ "$ALLOW_DOWNGRADE" != "true" ]; then
    die "$VERSION is older than the installed $installed; pass --allow-downgrade to roll back on purpose"
fi
check_release "$network-$VERSION"

# 4. Plan and confirmation.
cat <<EOF

Plan for $INSTANCE_ID ($REGION):
  network            $network
  installed release  $installed (node.service: $service)
  target release     $VERSION$( [ "$ALLOW_DOWNGRADE" = "true" ] && echo "  (DOWNGRADE)" )
  steps              install + verify binaries, restart node.service, wait for /health
  impact             RPC unavailable while sui-node restarts and catches up (minutes)

After success, the stack still names $installed. Run 'scripts/bump.sh $network $VERSION' and
'cdk deploy' at the next planned window (that redeploy stops/starts the instance).
EOF
if [ "$DRY_RUN" = "true" ]; then
    echo "(dry run) no changes made"
    exit 0
fi
if [ "$YES" != "true" ]; then
    printf 'Type "upgrade" to continue: '
    read -r answer
    [ "$answer" = "upgrade" ] || die "aborted"
fi

# 5. Upgrade on the instance. VERSION and network are validated above.
echo "Upgrading over SSM (download, verify, restart, wait for health; up to ~30 minutes)..."
ssm_run "set -eu
VERSION='$VERSION'
NETWORK='$network'
bash /opt/blueprints/user-data/common/install-sui-binaries.sh \"\$VERSION\" $( [ "$ALLOW_DOWNGRADE" = "true" ] && echo "--allow-downgrade" )
case \"\$(cat /home/bcuser/bin/.sui-release)\" in
    \"sui-\$NETWORK-\$VERSION-ubuntu-\"*) ;;
    *) echo \"ERROR: installed release marker does not match \$NETWORK-\$VERSION\"; exit 1 ;;
esac
systemctl restart node
TOKEN=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
IP=\$(curl -s -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/local-ipv4)
i=0
while [ \$i -lt 120 ]; do
    if curl -fsS -o /dev/null --max-time 5 \"http://\$IP:9000/health?threshold_seconds=120\"; then
        echo \"node healthy and in sync after \$((i * 10)) s\"
        /home/bcuser/bin/sui-node --version
        exit 0
    fi
    i=\$((i + 1))
    sleep 10
done
echo 'ERROR: node not healthy within 20 minutes'
systemctl status node --no-pager | tail -20
exit 1" 2400

echo
echo "Done. Next: scripts/bump.sh $network $VERSION, review, validate, and cdk deploy at a planned window."
