#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Restore the latest Sui formal snapshot into the node database.
#
# Uses `sui-tool download-formal-snapshot --no-sign-request`, which reads the
# free Mysten Labs endpoint for the network (https://formal-snapshot.<network>.sui.io)
# and cryptographically verifies the restored live-object set against the
# committee's end-of-epoch commitment (--verify normal, the default).
#
# sui-tool writes to <db-path>/staging and renames it to <db-path>/live only
# after a successful restore, so the existence of <db-path>/live is a reliable
# "already restored" guard. A failed restore leaves no live/ directory and
# exits non-zero; the framework retries setup on the next boot.
#
# Formal snapshots contain the live object set only (no historical
# transactions). With rpc.enable-indexing the node builds its gRPC indexes
# from that state on first start.

set -euo pipefail

# shellcheck disable=SC1091  # written by the framework at boot
source /etc/cdk_environment

SUI_BIN_DIR="/home/bcuser/bin"
SUI_CONFIG_DIR="/home/bcuser/sui-config"
DB_PATH="/data/sui/db"
SNAPSHOT_SENTINEL="/data/snapshot_downloaded"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] [sui-snapshot] $1"; }

if [ -d "$DB_PATH/live" ]; then
    log "Existing database found at $DB_PATH/live; skipping snapshot restore"
    exit 0
fi

if [ "${SNAPSHOT_ENABLED:-true}" != "true" ]; then
    log "WARNING: SNAPSHOT_ENABLED is not true and no database exists. sui-node will sync from genesis,"
    log "WARNING: which Sui does not recommend: seed peers keep only a few epochs, so this needs archival fallback and takes a very long time."
    exit 0
fi

case "${BC_NETWORK:-}" in
    mainnet|testnet) ;;
    *) log "ERROR: unsupported BC_NETWORK '${BC_NETWORK:-}'" >&2; exit 1 ;;
esac

mkdir -p "$DB_PATH"
chown -R bcuser:bcuser /data/sui

# sui-tool tuning. Defaults equal sui-tool's own (checked in v1.82.3, v1.83.0
# and v1.83.1 source), so
# behaviour only changes when set: --max-retries per HTTP request (default 10),
# --num-parallel-downloads (default 50, sui-tool caps it at 200).
MAX_RETRIES="${SUI_SNAPSHOT_MAX_RETRIES:-10}"
PARALLEL_DOWNLOADS="${SUI_SNAPSHOT_PARALLEL_DOWNLOADS:-50}"
if ! printf '%s' "$MAX_RETRIES" | grep -Eq '^[0-9]+$'; then
    log "ERROR: SUI_SNAPSHOT_MAX_RETRIES must be a non-negative integer (got '$MAX_RETRIES')" >&2
    exit 1
fi
if ! printf '%s' "$PARALLEL_DOWNLOADS" | grep -Eq '^[0-9]+$' \
    || [ "$PARALLEL_DOWNLOADS" -lt 1 ] || [ "$PARALLEL_DOWNLOADS" -gt 200 ]; then
    log "ERROR: SUI_SNAPSHOT_PARALLEL_DOWNLOADS must be an integer from 1 to 200 (got '$PARALLEL_DOWNLOADS')" >&2
    exit 1
fi

ATTEMPTS=3
for attempt in $(seq 1 "$ATTEMPTS"); do
    log "Restoring latest $BC_NETWORK formal snapshot into $DB_PATH (attempt $attempt/$ATTEMPTS, parallel=$PARALLEL_DOWNLOADS, max-retries=$MAX_RETRIES)"
    if runuser -u bcuser -- "$SUI_BIN_DIR/sui-tool" download-formal-snapshot \
        --latest \
        --network "$BC_NETWORK" \
        --genesis "$SUI_CONFIG_DIR/genesis.blob" \
        --path "$DB_PATH" \
        --num-parallel-downloads "$PARALLEL_DOWNLOADS" \
        --max-retries "$MAX_RETRIES" \
        --no-sign-request; then
        if [ -d "$DB_PATH/live" ]; then
            touch "$SNAPSHOT_SENTINEL"
            log "Formal snapshot restored"
            exit 0
        fi
        log "WARNING: sui-tool exited 0 but $DB_PATH/live does not exist"
    fi
    log "Snapshot restore attempt $attempt failed"
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep 60
done

log "ERROR: formal snapshot restore failed after $ATTEMPTS attempts" >&2
exit 1
