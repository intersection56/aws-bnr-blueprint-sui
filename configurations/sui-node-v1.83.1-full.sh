#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sui full node (sui-node) - RPC full node configuration
#
#   "install" - called by node.sh during setup: downloads and verifies the
#               sui-node / sui-tool release binaries and genesis.blob, writes
#               fullnode.yaml, and restores the latest formal snapshot
#   no args   - systemd entrypoint (/home/bcuser/bin/start-node.sh): exec's
#               sui-node as bcuser
#
# The client version is derived from the configuration file name
# ("sui-node-vX.Y.Z-full.sh" -> "vX.Y.Z"), which is the single source of
# truth. Sui publishes a separate release per network, so the GitHub release
# tag is "${BC_NETWORK}-${version}" (e.g. "mainnet-vX.Y.Z"). Install fails if
# that release does not exist for the selected network.
#
# All client logic shared between versions lives in
# /opt/blueprints/user-data/common/ so versioned configuration files stay
# identical apart from their name.

set -euo pipefail

SUI_BIN_DIR="/home/bcuser/bin"
SUI_CONFIG_DIR="/home/bcuser/sui-config"
COMMON_DIR="/opt/blueprints/user-data/common"

# --- Install phase: called by node.sh (as root) ---
install_client() {
    # shellcheck disable=SC1091  # written by the framework at boot
    source /etc/cdk_environment

    local sui_version
    sui_version=$(printf '%s' "${CLIENT_CONFIG:-}" | sed -nE 's/^sui-node-(v[0-9]+\.[0-9]+\.[0-9]+)-full\.sh$/\1/p')
    if [ -z "$sui_version" ]; then
        echo "ERROR: could not parse sui-node version from CLIENT_CONFIG '${CLIENT_CONFIG:-<unset>}'" >&2
        exit 1
    fi
    echo "sui-node version (from configuration name): $sui_version"

    bash "$COMMON_DIR/install-sui-binaries.sh" "$sui_version"
    bash "$COMMON_DIR/write-fullnode-config.sh"
    bash "$COMMON_DIR/download-snapshot.sh"

    echo "sui-node ${BC_NETWORK}-${sui_version} full node installation complete"
}

# --- Runtime phase: systemd entrypoint (runs as bcuser) ---
# Environment comes from systemd's EnvironmentFile=/etc/cdk_environment; that
# file is root-only, so it is not sourced here.
run_node() {
    export RUST_LOG="${SUI_RUST_LOG:-info}"
    exec "$SUI_BIN_DIR/sui-node" --config-path "$SUI_CONFIG_DIR/fullnode.yaml"
}

case "${1:-run}" in
    install)
        install_client
        ;;
    run|"")
        run_node
        ;;
    *)
        echo "Usage: $0 {install|run}" >&2
        exit 1
        ;;
esac
