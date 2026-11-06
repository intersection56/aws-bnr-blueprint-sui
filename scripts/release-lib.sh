#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for scripts/check-release.sh and scripts/bump.sh. Source it;
# do not run it. Works with macOS bash 3.2 and GNU bash.
#
# Sui publishes a separate release per network (tags "mainnet-vX.Y.Z",
# "testnet-vX.Y.Z"). This blueprint pins one release per network through the
# CLIENT_CONFIG of that network's samples (samples/.env-<network>-*); the
# version lives only in the configuration file name, sui-node-vX.Y.Z-full.sh.

SUI_REPO="MystenLabs/sui"
CONFIG_PREFIX="sui-node-"
CONFIG_SUFFIX="-full.sh"
# shellcheck disable=SC2034  # used by scripts that source this file (bump.sh)
VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

die() { echo "error: $*" >&2; exit 1; }

# Networks the blueprint supports, from package.json, one per line.
networks() {
    jq -r '."aws-blockchain-node-runner".BC_NETWORKS[]' package.json
}

config_for_version() { printf '%s%s%s\n' "$CONFIG_PREFIX" "$1" "$CONFIG_SUFFIX"; }

version_of_config() {
    printf '%s\n' "$1" | sed -nE 's/^sui-node-(v[0-9]+\.[0-9]+\.[0-9]+)-full\.sh$/\1/p'
}

# Sample files for a network.
samples_for() { ls samples/.env-"$1"-* 2>/dev/null; }

# CLIENT_CONFIG pinned by a network's samples. Fails if they disagree.
pinned_config() {
    local net="$1" f cfg found=""
    for f in $(samples_for "$net"); do
        cfg=$(sed -nE 's/^CLIENT_CONFIG="?([^"]*)"?$/\1/p' "$f")
        [ -n "$cfg" ] || die "$f has no CLIENT_CONFIG"
        if [ -z "$found" ]; then
            found="$cfg"
        elif [ "$cfg" != "$found" ]; then
            die "samples for $net disagree: $found vs $cfg ($f)"
        fi
    done
    [ -n "$found" ] || die "no samples for network '$net'"
    printf '%s\n' "$found"
}

# GitHub API GET. Uses GH_TOKEN when set (higher rate limit in CI).
gh_get() {
    local url="https://api.github.com/$1"
    if [ -n "${GH_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$url"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$url"
    fi
}

# Latest published (non-draft, non-prerelease) "<network>-vX.Y.Z" tag.
latest_tag() {
    local net="$1"
    gh_get "repos/$SUI_REPO/releases?per_page=100" \
        | jq -r --arg net "$net" '.[] | select(.draft == false and .prerelease == false)
                                      | .tag_name | select(test("^" + $net + "-v[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
        | sort -V | tail -1
}

# Newer of two vX.Y.Z versions.
newer_version() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }

# Fail unless release <tag> is published (not draft/prerelease) with SHA-256
# digests for the ubuntu-x86_64 and ubuntu-aarch64 archives.
check_release() {
    local tag="$1" json arch
    json="$(gh_get "repos/$SUI_REPO/releases/tags/$tag")" || die "release $tag not found in $SUI_REPO"
    [ "$(printf '%s' "$json" | jq -r '.draft or .prerelease')" = "false" ] || die "$tag is a draft or prerelease"
    for arch in ubuntu-x86_64 ubuntu-aarch64; do
        printf '%s' "$json" | jq -e --arg n "sui-$tag-$arch.tgz" \
            '.assets[] | select(.name == $n) | .digest | select(. != null and startswith("sha256:"))' >/dev/null \
            || die "$tag has no sui-$tag-$arch.tgz with a SHA-256 digest"
    done
    echo "release $tag: published, x86_64 and aarch64 archives have SHA-256 digests"
}
