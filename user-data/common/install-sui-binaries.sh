#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Install the sui-node and sui-tool binaries for "${BC_NETWORK}-<version>" and
# the network's genesis.blob. Runs as root from the configuration script's
# install phase.
#
# Usage: install-sui-binaries.sh <version> [--allow-downgrade]     (e.g. v1.83.1)
#
# Integrity:
#   - The release tarball is verified against the SHA-256 digest GitHub
#     publishes for the release asset. A missing digest fails closed.
#   - genesis.blob is verified against a pinned SHA-256 per network. Genesis
#     never changes for a live network; a mismatch fails closed.
#
# Re-run contract: binaries are replaced to match the requested version on
# every run (skipped when the installed release marker already matches);
# genesis is re-verified and only re-downloaded when missing or wrong.
#
# Never-downgrade safeguard (ADR-0022): a single node can be upgraded in place
# (scripts/upgrade-in-place.sh) without changing the stack. When setup re-runs
# later (stop/start, host maintenance) with the stack's older CLIENT_CONFIG,
# the newer installed release for the same network is kept, because an older
# sui-node may be unable to follow the chain after a protocol upgrade. Set
# SUI_ALLOW_DOWNGRADE="true" in .env to roll back on purpose.

set -euo pipefail

# shellcheck disable=SC1091  # written by the framework at boot
source /etc/cdk_environment
# shellcheck source=user-data/common/sui-version.sh
source "$(dirname "${BASH_SOURCE[0]}")/sui-version.sh"

SUI_VERSION="${1:-}"
SUI_ALLOW_DOWNGRADE="${SUI_ALLOW_DOWNGRADE:-false}"
# Second argument: an operator rolling back in place (scripts/upgrade-in-place.sh
# --allow-downgrade). A CLI flag rather than an environment variable, because
# /etc/cdk_environment (sourced above) sets SUI_ALLOW_DOWNGRADE from the stack.
case "${2:-}" in
    "") ;;
    --allow-downgrade) SUI_ALLOW_DOWNGRADE="true" ;;
    *) echo "usage: install-sui-binaries.sh <vX.Y.Z> [--allow-downgrade]" >&2; exit 1 ;;
esac
SUI_BIN_DIR="/home/bcuser/bin"
SUI_CONFIG_DIR="/home/bcuser/sui-config"
DOWNLOAD_DIR="/data/.sui-download"
RELEASE_MARKER="$SUI_BIN_DIR/.sui-release"

# Pinned genesis checksums (https://github.com/MystenLabs/sui-genesis). These
# are public SHA-256 digests of public files, not secrets; the pragma stops
# detect-secrets flagging them as high-entropy strings.
GENESIS_SHA256_MAINNET="b57abe29e52ea89b68df6d08224c234f6e2cb1fa357203b12ba50dd4776f9038" # pragma: allowlist secret
GENESIS_SHA256_TESTNET="df78eb5e525294d29c9f710a0d80c3b8e5c9f6e2e6485098584f0695d80de2aa" # pragma: allowlist secret

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] [install-sui] $1"; }

if ! printf '%s' "$SUI_VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    log "ERROR: invalid sui version '${SUI_VERSION}' (expected vX.Y.Z)" >&2
    exit 1
fi
case "$SUI_ALLOW_DOWNGRADE" in
    true|false) ;;
    *) log "ERROR: SUI_ALLOW_DOWNGRADE must be true or false, got '${SUI_ALLOW_DOWNGRADE}'" >&2; exit 1 ;;
esac

case "${BC_NETWORK:-}" in
    mainnet) GENESIS_SHA256="$GENESIS_SHA256_MAINNET" ;;
    testnet) GENESIS_SHA256="$GENESIS_SHA256_TESTNET" ;;
    *) log "ERROR: unsupported BC_NETWORK '${BC_NETWORK:-}' (expected mainnet or testnet)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64)  ASSET_ARCH="ubuntu-x86_64" ;;
    aarch64) ASSET_ARCH="ubuntu-aarch64" ;;
    *) log "ERROR: unsupported CPU architecture $(uname -m)" >&2; exit 1 ;;
esac

RELEASE_TAG="${BC_NETWORK}-${SUI_VERSION}"
ASSET_NAME="sui-${RELEASE_TAG}-${ASSET_ARCH}.tgz"

# Tools used below (Ubuntu host)
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq jq curl ca-certificates
fi

mkdir -p "$SUI_BIN_DIR" "$SUI_CONFIG_DIR"

# --- sui-node / sui-tool ---
INSTALLED_MARKER="$(cat "$RELEASE_MARKER" 2>/dev/null || true)"
if [ -x "$SUI_BIN_DIR/sui-node" ] && [ -x "$SUI_BIN_DIR/sui-tool" ] \
    && NEWER_INSTALLED="$(sui_keep_newer_installed "$SUI_VERSION" "$BC_NETWORK" "$INSTALLED_MARKER" "$SUI_ALLOW_DOWNGRADE")"; then
    log "WARNING: ${BC_NETWORK}-${NEWER_INSTALLED} is installed (upgraded in place) and is newer than the requested ${SUI_VERSION}; keeping it. Bump CLIENT_CONFIG to ${NEWER_INSTALLED} and redeploy, or set SUI_ALLOW_DOWNGRADE=true to roll back"
elif [ -x "$SUI_BIN_DIR/sui-node" ] && [ -x "$SUI_BIN_DIR/sui-tool" ] \
    && [ "$INSTALLED_MARKER" = "$ASSET_NAME" ]; then
    log "Release $ASSET_NAME already installed; skipping download"
else
    log "Resolving release $RELEASE_TAG asset $ASSET_NAME"
    RELEASE_JSON=$(curl -fsSL --retry 5 --retry-delay 10 \
        "https://api.github.com/repos/MystenLabs/sui/releases/tags/${RELEASE_TAG}") || {
        log "ERROR: release ${RELEASE_TAG} not found. Sui publishes per-network releases; check that ${SUI_VERSION} exists for ${BC_NETWORK} at https://github.com/MystenLabs/sui/releases" >&2
        exit 1
    }
    ASSET_URL=$(printf '%s' "$RELEASE_JSON" | jq -r --arg n "$ASSET_NAME" '.assets[] | select(.name==$n) | .browser_download_url')
    EXPECTED_SHA=$(printf '%s' "$RELEASE_JSON" | jq -r --arg n "$ASSET_NAME" '.assets[] | select(.name==$n) | .digest // empty' | sed 's/^sha256://')

    if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
        log "ERROR: asset $ASSET_NAME not found in release $RELEASE_TAG" >&2
        exit 1
    fi
    case "$ASSET_URL" in
        https://github.com/MystenLabs/sui/releases/download/*) ;;
        *) log "ERROR: unexpected asset URL '$ASSET_URL'" >&2; exit 1 ;;
    esac
    if ! printf '%s' "$EXPECTED_SHA" | grep -Eq '^[0-9a-f]{64}$'; then
        log "ERROR: release metadata has no SHA-256 digest for $ASSET_NAME; refusing to install an unverified binary" >&2
        exit 1
    fi

    # Download into /data (the root volume may be too small for the ~1.2 GB archive)
    rm -rf "$DOWNLOAD_DIR"
    mkdir -p "$DOWNLOAD_DIR"
    log "Downloading $ASSET_URL"
    curl -fsSL --retry 5 --retry-delay 10 -o "$DOWNLOAD_DIR/$ASSET_NAME" "$ASSET_URL"

    ACTUAL_SHA=$(sha256sum "$DOWNLOAD_DIR/$ASSET_NAME" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        log "ERROR: checksum mismatch for $ASSET_NAME (expected $EXPECTED_SHA, got $ACTUAL_SHA)" >&2
        rm -rf "$DOWNLOAD_DIR"
        exit 1
    fi
    log "SHA-256 verified"

    # Only extract the two binaries the node needs
    tar -xzf "$DOWNLOAD_DIR/$ASSET_NAME" -C "$DOWNLOAD_DIR" ./sui-node ./sui-tool
    install -m 0755 -o bcuser -g bcuser "$DOWNLOAD_DIR/sui-node" "$SUI_BIN_DIR/sui-node"
    install -m 0755 -o bcuser -g bcuser "$DOWNLOAD_DIR/sui-tool" "$SUI_BIN_DIR/sui-tool"
    printf '%s\n' "$ASSET_NAME" > "$RELEASE_MARKER"
    rm -rf "$DOWNLOAD_DIR"
    log "Installed: $("$SUI_BIN_DIR/sui-node" --version 2>/dev/null || echo "$RELEASE_TAG")"
fi

# --- genesis.blob ---
GENESIS_FILE="$SUI_CONFIG_DIR/genesis.blob"
genesis_ok() {
    [ -f "$GENESIS_FILE" ] && [ "$(sha256sum "$GENESIS_FILE" | awk '{print $1}')" = "$GENESIS_SHA256" ]
}
if genesis_ok; then
    log "genesis.blob for $BC_NETWORK already present and verified"
else
    log "Downloading genesis.blob for $BC_NETWORK"
    curl -fsSL --retry 5 --retry-delay 10 -o "$GENESIS_FILE.tmp" \
        "https://github.com/MystenLabs/sui-genesis/raw/main/${BC_NETWORK}/genesis.blob"
    mv "$GENESIS_FILE.tmp" "$GENESIS_FILE"
    if ! genesis_ok; then
        log "ERROR: genesis.blob checksum does not match the pinned value for $BC_NETWORK" >&2
        rm -f "$GENESIS_FILE"
        exit 1
    fi
    log "genesis.blob verified"
fi

chown -R bcuser:bcuser "$SUI_BIN_DIR" "$SUI_CONFIG_DIR"
