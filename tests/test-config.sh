#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/magisk-hotspot-test-$$
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/runtime"
cp "$ROOT/config.yml" "$TMP/config.yml"
cp "$ROOT/module.prop" "$TMP/module.prop"

MODDIR=$ROOT
MAGISK_HOTSPOT_CONFIG="$TMP/config.yml"
MAGISK_HOTSPOT_RUNDIR="$TMP/runtime"
MAGISK_HOTSPOT_MODULE_PROP="$TMP/module.prop"
export MAGISK_HOTSPOT_CONFIG MAGISK_HOTSPOT_RUNDIR MAGISK_HOTSPOT_MODULE_PROP
. "$ROOT/scripts/common.sh"

# Empty optional values are valid and disable their corresponding features.
load_config
[ -z "$SSID" ]
[ -z "$PASSWORD" ]
[ "$BAND_ARG" = any ]
[ -z "$IP_CIDR" ]
[ -z "$IP_ADDRESS" ]
[ -z "$DNS_DOMAIN" ]
[ "$KEEP_ALIVE" = true ]

set_module_running_description 192.168.43.1 ""
[ "$(sed -n 's/^description=//p' "$TMP/module.prop")" = "IP: 192.168.43.1" ]
set_module_running_description 192.168.50.1 magisk.home.arpa
[ "$(sed -n 's/^description=//p' "$TMP/module.prop")" = \
  "IP: 192.168.50.1 | DNS: magisk.home.arpa" ]
[ "$(grep -c '^description=' "$TMP/module.prop")" -eq 1 ]
set_module_inactive_description
[ "$(sed -n 's/^description=//p' "$TMP/module.prop")" = "Hotspot inactive" ]

sed \
  -e 's/ssid: ""/ssid: "TestHotspot"/' \
  -e 's/password: ""/password: "abc#12345"/' \
  -e 's/band: "auto"/band: "2.4GHz"/' \
  -e 's/ip_address: ""/ip_address: "192.168.50.1\/32"/' \
  -e 's/domain: ""/domain: "HOST-01.Example."/' \
  "$ROOT/config.yml" > "$TMP/config.yml"
load_config
[ "$SSID" = TestHotspot ]
[ "$PASSWORD" = 'abc#12345' ]
[ "$BAND_ARG" = 2 ]
[ "$IP_CIDR" = 192.168.50.1/32 ]
[ "$IP_ADDRESS" = 192.168.50.1 ]
[ "$DNS_DOMAIN" = host-01.example ]

sed 's/2.4GHz/invalid/' "$TMP/config.yml" > "$TMP/invalid.yml"
MAGISK_HOTSPOT_CONFIG="$TMP/invalid.yml"
CONFIG_FILE=$MAGISK_HOTSPOT_CONFIG
if load_config; then
  echo "invalid band was accepted" >&2
  exit 1
fi

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

# Non-empty passwords are still required to meet WPA2 length constraints.
sed 's/password: "abc#12345"/password: "short"/' "$TMP/config.yml" > "$TMP/invalid.yml"
CONFIG_FILE="$TMP/invalid.yml"
if load_config; then
  echo "short password was accepted" >&2
  exit 1
fi

# A config preserved from before DNS support now leaves DNS disabled.
awk '
  /^dns:/ { skip = 1; next }
  skip && /^[^[:space:]]/ { skip = 0 }
  !skip { print }
' "$TMP/config.yml" > "$TMP/pre-dns.yml"
CONFIG_FILE="$TMP/pre-dns.yml"
load_config
[ -z "$DNS_DOMAIN" ]

echo "config tests passed"
