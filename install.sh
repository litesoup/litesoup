#!/usr/bin/env bash
# install.sh — litesoup quick installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/litesoup/litesoup/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/litesoup/litesoup/main/install.sh | sudo bash -s -- --php-versions=8.2,8.4
#   LITESOUP_PPA_FORCE_MIRROR=cloudpanel curl -fsSL ... | sudo bash
#
# Shallow-clones the repo, runs install-stack.sh, and cleans up.
set -Eeuo pipefail

LITESOUP_TMP="$(mktemp -d)"
trap 'rm -rf "${LITESOUP_TMP}"' EXIT

echo "litesoup: cloning into ${LITESOUP_TMP}..."
git clone --depth=1 https://github.com/litesoup/litesoup.git "${LITESOUP_TMP}"

cd "${LITESOUP_TMP}"
exec bash install/install-stack.sh "$@"
