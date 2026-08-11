#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/dist"
ZIP="$OUT/magisk-hotspot-v1.1.0.zip"

"$ROOT/tools/build-hotspotctl.sh"
mkdir -p "$OUT"
rm -f "$ZIP"

cd "$ROOT"
zip -9 -r "$ZIP" \
  module.prop config.yml README.md service.sh action.sh customize.sh uninstall.sh \
  scripts bin/hotspotctl.dex \
  -x '*.DS_Store'

printf 'Built %s\n' "$ZIP"
