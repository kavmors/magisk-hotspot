#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/magisk-hotspot-dns-test-$$
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP"

javac -source 8 -target 8 -Xlint:-options -d "$TMP" \
  "$ROOT/tools/src/DnsMessage.java" "$ROOT/tests/DnsMessageTest.java"
java -cp "$TMP" DnsMessageTest
