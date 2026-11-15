#!/usr/bin/env bash
# The default VPS installer now uses native systemd hosting.
set -Eeuo pipefail
installer=$(mktemp /tmp/ambersight-native.XXXXXX.sh)
trap 'rm -f "$installer"' EXIT
curl -fsSL --retry 3 https://raw.githubusercontent.com/waqaarhussain/AmberSight/master/scripts/setup-native.sh -o "$installer"
bash "$installer" "$@"
