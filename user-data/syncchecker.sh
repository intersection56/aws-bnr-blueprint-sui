#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sui sync checker, metrics reporter and traffic shaping controller.
# Run by the framework's syncchecker.timer every TRAFFIC_SHAPING_CHECK_INTERVAL_SEC.
#
# Reads sui-node's Prometheus endpoint on 127.0.0.1:9184 and reports to
# CloudWatch (namespace CWAgent, dimension InstanceId):
#   c1_block_height    last_executed_checkpoint
#   c1_blocks_behind   highest_known_checkpoint - last_executed_checkpoint
#   c1_seconds_behind  now - last_executed_checkpoint_timestamp_ms
# plus c1_seconds_behind with dimension StackName, for one lag alarm per stack.
#
# Sui produces checkpoints (its unit of "blocks") several times per second,
# so set TRAFFIC_SHAPING_MAX_BLOCKS_BEHIND in checkpoints accordingly.

set -uo pipefail

# shellcheck disable=SC1091  # written by the framework at boot
source /etc/cdk_environment 2>/dev/null || true

TRAFFIC_SHAPING_ENABLED="${TRAFFIC_SHAPING_ENABLED:-false}"
TRAFFIC_SHAPING_MAX_BLOCKS_BEHIND="${TRAFFIC_SHAPING_MAX_BLOCKS_BEHIND:-300}"
METRICS_URL="http://127.0.0.1:9184/metrics"
# A node whose last executed checkpoint is older than this is treated as
# behind even if highest_known_checkpoint has not moved (e.g. no peers).
STALE_SECONDS=120

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] [syncchecker] $1"; }

# The framework starts net-rules.service (the outbound rate limit) during setup
# whether or not TRAFFIC_SHAPING_ENABLED is true. Keep it off whenever this
# checker is not actively managing it: during bootstrap (the snapshot restore
# makes many parallel requests to Sui's public endpoints, and two restore
# attempts timed out with shaping on in the 2026-11-03 test) and when shaping
# is disabled.
shaping_off() {
    if systemctl is-active --quiet net-rules.service 2>/dev/null; then
        log "$1; stopping traffic shaping"
        systemctl stop net-rules.service || log "Failed to stop net-rules.service"
    fi
}

if [ ! -f /data/init-completed ]; then
    shaping_off "Node initialization not complete yet"
    log "Node initialization not complete yet, skipping sync check"
    exit 0
fi

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region // empty')
REGION="${REGION:-${AWS_REGION:-}}"
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%:z")

METRICS=$(curl -s --max-time 10 "$METRICS_URL" || true)

# Read an unlabelled or labelled gauge: "<name>[{...}] <value>"
metric() {
    printf '%s\n' "$METRICS" | awk -v n="$1" '
        $0 !~ /^#/ { split($1, a, "{"); if (a[1] == n) { v = $2; if (v ~ /^[0-9]+$/) printf "%s", v; else printf "%.0f", v; found=1; exit } }
        END { if (!found) printf "" }'
}

LAST_EXECUTED=$(metric last_executed_checkpoint)
HIGHEST_KNOWN=$(metric highest_known_checkpoint)
LAST_EXECUTED_TS_MS=$(metric last_executed_checkpoint_timestamp_ms)

if [ -z "$LAST_EXECUTED" ]; then
    log "sui-node metrics not available yet at $METRICS_URL (node starting, restoring or building indexes)"
    c1_block_height=0
    c1_blocks_behind=0
    c1_seconds_behind=0
    METRICS_OK=false
else
    METRICS_OK=true
    c1_block_height="$LAST_EXECUTED"
    c1_blocks_behind=$(( ${HIGHEST_KNOWN:-$LAST_EXECUTED} - LAST_EXECUTED ))
    [ "$c1_blocks_behind" -lt 0 ] && c1_blocks_behind=0
    if [ -n "$LAST_EXECUTED_TS_MS" ] && [ "$LAST_EXECUTED_TS_MS" -gt 0 ]; then
        c1_seconds_behind=$(( $(date +%s) - LAST_EXECUTED_TS_MS / 1000 ))
        [ "$c1_seconds_behind" -lt 0 ] && c1_seconds_behind=0
    else
        c1_seconds_behind=0
    fi
fi

log "checkpoint=$c1_block_height checkpoints_behind=$c1_blocks_behind seconds_behind=$c1_seconds_behind"

put_metric() {
    aws cloudwatch put-metric-data \
        --namespace "CWAgent" \
        --metric-name "$1" \
        --value "$2" \
        --timestamp "$TIMESTAMP" \
        --dimensions "InstanceId=$INSTANCE_ID" \
        --region "$REGION" || log "Failed to send $1 metric"
}

if command -v aws >/dev/null 2>&1 && [ -n "$REGION" ] && [ -n "$INSTANCE_ID" ]; then
    put_metric c1_block_height "$c1_block_height"
    put_metric c1_blocks_behind "$c1_blocks_behind"
    put_metric c1_seconds_behind "$c1_seconds_behind"
    # Stack-level copy for the lag alarm (ADR-0023): every node in the stack
    # publishes to the same series, so one alarm on its Maximum covers all nodes
    # and survives HA replacements (per-instance alarms would not). Published
    # only once metrics are available, so a node still bootstrapping does not
    # report a misleading 0. STACK_NAME comes from /etc/cdk_environment.
    if [ "$METRICS_OK" = "true" ] && [ -n "${STACK_NAME:-}" ]; then
        aws cloudwatch put-metric-data \
            --namespace "CWAgent" \
            --metric-name c1_seconds_behind \
            --value "$c1_seconds_behind" \
            --timestamp "$TIMESTAMP" \
            --dimensions "StackName=$STACK_NAME" \
            --region "$REGION" || log "Failed to send stack-level c1_seconds_behind metric"
    fi
else
    log "AWS CLI, region or instance ID unavailable; skipping CloudWatch metrics"
fi

# --- Traffic shaping control ---
if [ "$TRAFFIC_SHAPING_ENABLED" != "true" ]; then
    shaping_off "Traffic shaping disabled (TRAFFIC_SHAPING_ENABLED=$TRAFFIC_SHAPING_ENABLED)"
    exit 0
fi
# `systemctl cat` instead of `list-unit-files | grep -q`: under pipefail, grep -q
# exits on the first match, systemctl gets SIGPIPE (141) and the check fails at
# random (observed on the test instance 2026-11-03: 3 of 5 runs).
if ! systemctl cat net-rules.service >/dev/null 2>&1; then
    log "net-rules.service not found, traffic shaping not available"
    exit 0
fi

BEHIND=false
if [ "$METRICS_OK" != "true" ] \
    || [ "$c1_blocks_behind" -gt "$TRAFFIC_SHAPING_MAX_BLOCKS_BEHIND" ] \
    || [ "$c1_seconds_behind" -gt "$STALE_SECONDS" ]; then
    BEHIND=true
fi

if [ "$BEHIND" = "true" ]; then
    if systemctl is-active --quiet net-rules.service; then
        log "Node is behind; disabling traffic shaping to allow catch-up"
        systemctl stop net-rules.service || log "Failed to stop net-rules.service"
    fi
else
    if ! systemctl is-active --quiet net-rules.service; then
        log "Node is in sync; enabling traffic shaping"
        systemctl start net-rules.service || log "Failed to start net-rules.service"
    fi
fi

exit 0
