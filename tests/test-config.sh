#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/magisk-hotspot-test-$$
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/runtime"
cp "$ROOT/config.yml" "$TMP/config.yml"

MODDIR=$ROOT
MAGISK_HOTSPOT_CONFIG="$TMP/config.yml"
MAGISK_HOTSPOT_RUNDIR="$TMP/runtime"
export MAGISK_HOTSPOT_CONFIG MAGISK_HOTSPOT_RUNDIR
. "$ROOT/scripts/common.sh"

load_config
[ "$SSID" = MagiskHotspot ]
[ "$PASSWORD" = change-me-123 ]
[ "$BAND_ARG" = 2 ]
[ "$IP_CIDR" = 192.168.50.1/32 ]
[ "$DNS_DOMAIN" = magisk.home.arpa ]
[ "$KEEP_ALIVE" = true ]

sed 's/change-me-123/abc#12345/' "$ROOT/config.yml" > "$TMP/config.yml"
load_config
[ "$PASSWORD" = 'abc#12345' ]

sed 's/2.4GHz/invalid/' "$ROOT/config.yml" > "$TMP/config.yml"
if load_config; then
  echo "invalid band was accepted" >&2
  exit 1
fi

sed 's/magisk.home.arpa/HOST-01.Example./' "$ROOT/config.yml" > "$TMP/config.yml"
load_config
[ "$DNS_DOMAIN" = host-01.example ]

for cidr in 192.168.1.1/32 10.0.0.1/32 172.16.8.1/32; do
  validate_ipv4_cidr "$cidr"
done
for cidr in 8.8.8.8/32 127.0.0.1/32 224.0.0.1/32 192.168.1.1/24 192.168.1/32; do
  if validate_ipv4_cidr "$cidr"; then
    echo "invalid CIDR was accepted: $cidr" >&2
    exit 1
  fi
done

for domain in magisk.home.arpa router.lan HOST-01.example x; do
  validate_dns_domain "$domain"
done
for domain in '' . bad..name -bad.example bad-.example 'bad name.example' 'bad_name.example'; do
  if validate_dns_domain "$domain"; then
    echo "invalid DNS domain was accepted: $domain" >&2
    exit 1
  fi
done

# Existing installations keep their config.yml during upgrades. Verify that a
# pre-DNS config gets the documented default instead of becoming invalid.
awk '
  /^dns:/ { skip = 1; next }
  skip && /^[^[:space:]]/ { skip = 0 }
  !skip { print }
' "$ROOT/config.yml" > "$TMP/config.yml"
load_config
[ "$DNS_DOMAIN" = magisk.home.arpa ]

echo "config tests passed"
