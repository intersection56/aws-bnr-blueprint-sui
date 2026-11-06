#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Write /home/bcuser/sui-config/fullnode.yaml for the selected network.
# Rewritten on every run (holds no secrets), so .env changes take effect on
# redeploy.
#
# Listeners:
#   RPC (gRPC, gRPC-Web, GET /health)  -> EC2 internal IP:9000 (VPC only)
#   P2P (state sync, discovery)        -> 0.0.0.0:8084/udp     (public)
#   Prometheus metrics                 -> 127.0.0.1:9184       (host only)
#   Admin API (no auth)                -> 127.0.0.1:1337       (host only, sui-node default)
#   Validator network address          -> 127.0.0.1:8080       (unused by full nodes)

set -euo pipefail

# shellcheck disable=SC1091  # written by the framework at boot
source /etc/cdk_environment

SUI_CONFIG_DIR="/home/bcuser/sui-config"
CONFIG_FILE="$SUI_CONFIG_DIR/fullnode.yaml"
DB_PATH="/data/sui/db"

RPC_PORT="9000"
P2P_PORT="8084"
METRICS_PORT="9184"
ADMIN_PORT="1337"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] [sui-config] $1"; }

require_uint() {
    if ! printf '%s' "$2" | grep -Eq '^[0-9]+$'; then
        log "ERROR: $1 must be a non-negative integer (got '$2')" >&2
        exit 1
    fi
}
require_bool() {
    case "$2" in
        true|false) ;;
        *) log "ERROR: $1 must be true or false (got '$2')" >&2; exit 1 ;;
    esac
}

ENABLE_INDEXING="${SUI_ENABLE_INDEXING:-true}"
EPOCHS_TO_RETAIN="${SUI_NUM_EPOCHS_TO_RETAIN:-5}"
EPOCHS_TO_RETAIN_CHECKPOINTS="${SUI_NUM_EPOCHS_TO_RETAIN_FOR_CHECKPOINTS:-2}"
ARCHIVE_FALLBACK="${SUI_ARCHIVE_FALLBACK:-auto}"

require_bool SUI_ENABLE_INDEXING "$ENABLE_INDEXING"
require_uint SUI_NUM_EPOCHS_TO_RETAIN "$EPOCHS_TO_RETAIN"
require_uint SUI_NUM_EPOCHS_TO_RETAIN_FOR_CHECKPOINTS "$EPOCHS_TO_RETAIN_CHECKPOINTS"
# Sui never prunes the current and immediately prior epoch; values below 2 are
# not meaningful for transaction pruning.
if [ "$EPOCHS_TO_RETAIN_CHECKPOINTS" -lt 2 ]; then
    log "ERROR: SUI_NUM_EPOCHS_TO_RETAIN_FOR_CHECKPOINTS must be >= 2" >&2
    exit 1
fi
case "$ARCHIVE_FALLBACK" in
    auto|true|false) ;;
    *) log "ERROR: SUI_ARCHIVE_FALLBACK must be auto, true or false (got '$ARCHIVE_FALLBACK')" >&2; exit 1 ;;
esac

# --- IMDSv2: internal IP (RPC bind) and optional public IP (P2P advertisement) ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
if [ -z "$TOKEN" ]; then
    log "ERROR: could not obtain an IMDSv2 token" >&2
    exit 1
fi
EC2_INTERNAL_IP=$(curl -s -f -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 || true)
if ! printf '%s' "$EC2_INTERNAL_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    log "ERROR: could not resolve EC2 internal IPv4 from IMDS (got '$EC2_INTERNAL_IP')" >&2
    exit 1
fi
EC2_PUBLIC_IP=$(curl -s -f -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || true)

# Advertise the public IP to peers when there is one. Without it the node still
# syncs (it dials seed peers outbound) but other peers cannot dial it.
EXTERNAL_ADDRESS_LINE=""
if printf '%s' "$EC2_PUBLIC_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    EXTERNAL_ADDRESS_LINE="  external-address: /ip4/${EC2_PUBLIC_IP}/udp/${P2P_PORT}"
    log "P2P external address: /ip4/${EC2_PUBLIC_IP}/udp/${P2P_PORT}"
else
    log "WARNING: instance has no public IPv4; P2P runs outbound-only"
fi

# --- Seed peers (https://docs.sui.io/operators/full-node/sui-full-node) ---
case "$BC_NETWORK" in
    mainnet)
        SEED_PEERS=$(cat <<'EOF'
    - address: /dns/mel-00.mainnet.sui.io/udp/8084
      peer-id: d32b55bdf1737ec415df8c88b3bf91e194b59ee3127e3f38ea46fd88ba2e7849
    - address: /dns/ewr-00.mainnet.sui.io/udp/8084
      peer-id: c7bf6cb93ca8fdda655c47ebb85ace28e6931464564332bf63e27e90199c50ee
    - address: /dns/ewr-01.mainnet.sui.io/udp/8084
      peer-id: 3227f8a05f0faa1a197c075d31135a366a1c6f3d4872cb8af66c14dea3e0eb66
    - address: /dns/lhr-00.mainnet.sui.io/udp/8084
      peer-id: c619a5e0f8f36eac45118c1f8bda28f0f508e2839042781f1d4a9818043f732c
    - address: /dns/sui-mainnet-ssfn-1.nodeinfra.com/udp/8084
      peer-id: 0c52ca8d2b9f51be4a50eb44ace863c05aadc940a7bd15d4d3f498deb81d7fc6
    - address: /dns/sui-mainnet-ssfn-2.nodeinfra.com/udp/8084
      peer-id: 1dbc28c105aa7eb9d1d3ac07ae663ea638d91f2b99c076a52bbded296bd3ed5c
    - address: /dns/sui-mainnet-ssfn-ashburn-na.overclock.run/udp/8084
      peer-id: 5ff8461ab527a8f241767b268c7aaf24d0312c7b923913dd3c11ee67ef181e45
    - address: /dns/sui-mainnet-ssfn-dallas-na.overclock.run/udp/8084
      peer-id: e1a4f40d66f1c89559a195352ba9ff84aec28abab1d3aa1c491901a252acefa6
    - address: /dns/ssn01.mainnet.sui.rpcpool.com/udp/8084
      peer-id: fadb7ccb0b7fc99223419176e707f5122fef4ea686eb8e80d1778588bf5a0bcd
    - address: /dns/ssn02.mainnet.sui.rpcpool.com/udp/8084
      peer-id: 13783584a90025b87d4604f1991252221e5fd88cab40001642f4b00111ae9b7e
EOF
)
        ;;
    testnet)
        SEED_PEERS=$(cat <<'EOF'
    - address: /dns/yto-tnt-ssfn-00.testnet.sui.io/udp/8084
      peer-id: 6563732e5ab33b4ae09c73a98fd37499b71b8f03c27b5cc51acc26934974aff2
    - address: /dns/yto-tnt-ssfn-01.testnet.sui.io/udp/8084
      peer-id: 2ed53564d5581ded9b6773970ac2f1c84d39f9edf01308ff5a1ffe09b1add7b3
    - address: /dns/nrt-tnt-ssfn-00.testnet.sui.io/udp/8084
      peer-id: 23a1f7cd901b6277cbedaa986b3fc183f171d800cabba863d48f698f518967e1
    - address: /dns/ewr-tnt-ssfn-00.testnet.sui.io/udp/8084
      peer-id: df8a8d128051c249e224f95fcc463f518a0ebed8986bbdcc11ed751181fecd38
    - address: /dns/lax-tnt-ssfn-00.testnet.sui.io/udp/8084
      peer-id: f9a72a0a6c17eed09c27898eab389add704777c03e135846da2428f516a0c11d
    - address: /dns/lhr-tnt-ssfn-00.testnet.sui.io/udp/8084
      peer-id: 9393d6056bb9c9d8475a3cf3525c747257f17c6a698a7062cbbd1875bc6ef71e
    - address: /dns/mel-tnt-ssfn-00.testnet.sui.io/udp/8084
      peer-id: c88742f46e66a11cb8c84aca488065661401ef66f726cb9afeb8a5786d83456e
EOF
)
        ;;
    *)
        log "ERROR: unsupported BC_NETWORK '${BC_NETWORK:-}' (expected mainnet or testnet)" >&2
        exit 1
        ;;
esac

# --- Archival fallback (lets a lagging node fetch checkpoints peers pruned) ---
# testnet: free HTTPS endpoint (30-day retention), on by default.
# mainnet: Requester Pays S3 bucket; needs s3:GetObject on
#          arn:aws:s3:::mysten-mainnet-checkpoints/* in the instance role and
#          bills egress to this account, so it is opt-in (SUI_ARCHIVE_FALLBACK=true).
ARCHIVE_BLOCK=""
if [ "$BC_NETWORK" = "testnet" ] && [ "$ARCHIVE_FALLBACK" != "false" ]; then
    ARCHIVE_BLOCK=$(cat <<'EOF'
state-archive-read-config:
  - ingestion-url: "https://checkpoints.testnet.sui.io"
    concurrency: 5
EOF
)
elif [ "$BC_NETWORK" = "mainnet" ] && [ "$ARCHIVE_FALLBACK" = "true" ]; then
    log "Mainnet archival fallback enabled (Requester Pays S3; instance role needs s3:GetObject on mysten-mainnet-checkpoints)"
    ARCHIVE_BLOCK=$(cat <<'EOF'
state-archive-read-config:
  - ingestion-url: "https://s3.us-west-2.amazonaws.com/mysten-mainnet-checkpoints"
    concurrency: 5
    remote-store-options:
      - ["aws_request_payer", "true"]
EOF
)
fi

mkdir -p "$SUI_CONFIG_DIR" "$DB_PATH"

cat > "$CONFIG_FILE.tmp" <<EOF
# Generated by aws-bnr-blueprint-sui (user-data/common/write-fullnode-config.sh).
# Rewritten on every setup run - edit the .env and redeploy instead.
db-path: "${DB_PATH}"

network-address: "/ip4/127.0.0.1/tcp/8080/http"
json-rpc-address: "${EC2_INTERNAL_IP}:${RPC_PORT}"
metrics-address: "127.0.0.1:${METRICS_PORT}"
admin-interface-port: ${ADMIN_PORT}

rpc:
  enable-indexing: ${ENABLE_INDEXING}

p2p-config:
  listen-address: "0.0.0.0:${P2P_PORT}"
${EXTERNAL_ADDRESS_LINE}
  seed-peers:
${SEED_PEERS}

genesis:
  genesis-file-location: "${SUI_CONFIG_DIR}/genesis.blob"

authority-store-pruning-config:
  num-latest-epoch-dbs-to-retain: 3
  epoch-db-pruning-period-secs: 3600
  num-epochs-to-retain: ${EPOCHS_TO_RETAIN}
  num-epochs-to-retain-for-checkpoints: ${EPOCHS_TO_RETAIN_CHECKPOINTS}
  max-checkpoints-in-batch: 10
  max-transactions-in-batch: 1000
  pruning-run-delay-seconds: 60
  periodic-compaction-threshold-days: 1

${ARCHIVE_BLOCK}
EOF
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

chown -R bcuser:bcuser "$SUI_CONFIG_DIR"
chmod 0644 "$CONFIG_FILE"
log "Wrote $CONFIG_FILE (network=$BC_NETWORK, rpc=${EC2_INTERNAL_IP}:${RPC_PORT}, indexing=$ENABLE_INDEXING)"
