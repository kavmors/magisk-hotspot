#!/system/bin/sh

CONFIG_FILE=${MAGISK_HOTSPOT_CONFIG:-"$MODDIR/config.yml"}
RUNDIR=${MAGISK_HOTSPOT_RUNDIR:-/data/adb/magisk-hotspot}
LOG_FILE="$RUNDIR/hotspot.log"
STATE_FILE="$RUNDIR/state"
CHAIN=MAGISK_HOTSPOT
DNS_CHAIN=MAGISK_HOTSPOT_DNS
DNS_PORT=1053
DNS_PID_FILE="$RUNDIR/dns-server.pid"
DNS_LOG_FILE="$RUNDIR/dns-server.log"

mkdir -p "$RUNDIR"
chmod 0700 "$RUNDIR" 2>/dev/null || true

rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null)
  case "$SIZE" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$SIZE" -gt 262144 ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.old"
  fi
}

log() {
  rotate_log
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
  command log -t MagiskHotspot "$*" 2>/dev/null || true
}

# Reads the intentionally small YAML subset used by config.yml. It supports
# two-space sections, scalar values, quotes, and comments outside quotes.
yaml_get() {
  SECTION=$1
  KEY=$2
  awk -v wanted_section="$SECTION" -v wanted_key="$KEY" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function uncomment(s,    i, c, q, out) {
      q = ""
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "" && (c == "\"" || c == "\047")) q = c
        else if (q != "" && c == q) q = ""
        else if (q == "" && c == "#") break
        out = out c
      }
      return trim(out)
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[^[:space:]][^:]*:[[:space:]]*/ {
      name = $0
      sub(/:.*/, "", name)
      in_section = (trim(name) == wanted_section)
      next
    }
    in_section {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      name = line
      sub(/:.*/, "", name)
      if (trim(name) != wanted_key) next
      sub(/^[^:]*:[[:space:]]*/, "", line)
      value = uncomment(line)
      if (length(value) >= 2) {
        first = substr(value, 1, 1)
        last = substr(value, length(value), 1)
        if ((first == "\"" && last == "\"") ||
            (first == "\047" && last == "\047")) {
          value = substr(value, 2, length(value) - 2)
        }
      }
      print value
      exit
    }
  ' "$CONFIG_FILE"
}

validate_uint() {
  VALUE=$1
  MIN=$2
  MAX=$3
  case "$VALUE" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$VALUE" -ge "$MIN" ] && [ "$VALUE" -le "$MAX" ]
}

validate_ipv4_cidr() {
  printf '%s\n' "$1" | awk -F '[/\.]' '
    NF != 5 { exit 1 }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ ||
      $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ { exit 1 }
    $1 < 1 || $1 > 223 || $2 > 255 || $3 > 255 || $4 > 255 ||
      $5 != 32 { exit 1 }
    $1 == 127 || ($1 == 169 && $2 == 254) { exit 1 }
    !($1 == 10 || ($1 == 172 && $2 >= 16 && $2 <= 31) ||
      ($1 == 192 && $2 == 168)) { exit 1 }
    { exit 0 }
  '
}

validate_dns_domain() {
  printf '%s\n' "$1" | awk '
    length($0) < 1 || length($0) > 253 { exit 1 }
    $0 !~ /^[A-Za-z0-9.-]+$/ { exit 1 }
    {
      value = $0
      sub(/\.$/, "", value)
      if (length(value) < 1 || length(value) > 253) exit 1
      count = split(value, labels, ".")
      for (i = 1; i <= count; i++) {
        if (length(labels[i]) < 1 || length(labels[i]) > 63 ||
            labels[i] !~ /^[A-Za-z0-9]/ || labels[i] !~ /[A-Za-z0-9]$/) {
          exit 1
        }
      }
      exit 0
    }
  '
}

load_config() {
  [ -r "$CONFIG_FILE" ] || {
    log "ERROR: cannot read $CONFIG_FILE"
    return 1
  }

  NEW_SSID=$(yaml_get hotspot ssid)
  NEW_PASSWORD=$(yaml_get hotspot password)
  NEW_BAND=$(yaml_get hotspot band)
  NEW_IP_CIDR=$(yaml_get network ip_address)
  NEW_DNS_DOMAIN=$(yaml_get dns domain)
  NEW_BOOT_DELAY=$(yaml_get behavior boot_delay_seconds)
  NEW_KEEP_ALIVE=$(yaml_get behavior keep_alive)
  NEW_RETRY_INTERVAL=$(yaml_get behavior retry_interval_seconds)

  [ -n "$NEW_SSID" ] && [ "${#NEW_SSID}" -le 32 ] || {
    log "ERROR: hotspot.ssid must contain 1-32 characters"
    return 1
  }
  [ "${#NEW_PASSWORD}" -ge 8 ] && [ "${#NEW_PASSWORD}" -le 63 ] || {
    log "ERROR: hotspot.password must contain 8-63 characters"
    return 1
  }

  case "$(printf '%s' "$NEW_BAND" | tr '[:upper:]' '[:lower:]')" in
    2|2.4|2.4g|2.4ghz) NEW_BAND_ARG=2 ;;
    5|5g|5ghz) NEW_BAND_ARG=5 ;;
    auto|any) NEW_BAND_ARG=any ;;
    *)
      log "ERROR: hotspot.band must be 2.4GHz, 5GHz, or auto"
      return 1
      ;;
  esac

  validate_ipv4_cidr "$NEW_IP_CIDR" || {
    log "ERROR: network.ip_address must be a valid private IPv4 /32 CIDR"
    return 1
  }
  # Config files preserved from versions before DNS support do not contain
  # this section, so upgrades use the same default as a fresh installation.
  [ -n "$NEW_DNS_DOMAIN" ] || NEW_DNS_DOMAIN=magisk.home.arpa
  validate_dns_domain "$NEW_DNS_DOMAIN" || {
    log "ERROR: dns.domain must be a valid DNS name"
    return 1
  }
  validate_uint "$NEW_BOOT_DELAY" 0 300 || {
    log "ERROR: behavior.boot_delay_seconds must be between 0 and 300"
    return 1
  }
  validate_uint "$NEW_RETRY_INTERVAL" 3 300 || {
    log "ERROR: behavior.retry_interval_seconds must be between 3 and 300"
    return 1
  }
  case "$NEW_KEEP_ALIVE" in
    true|false) ;;
    *)
      log "ERROR: behavior.keep_alive must be true or false"
      return 1
      ;;
  esac

  SSID=$NEW_SSID
  PASSWORD=$NEW_PASSWORD
  BAND=$NEW_BAND
  BAND_ARG=$NEW_BAND_ARG
  IP_CIDR=$NEW_IP_CIDR
  IP_ADDRESS=${IP_CIDR%/*}
  DNS_DOMAIN=$(printf '%s' "$NEW_DNS_DOMAIN" | sed 's/\.$//' | tr '[:upper:]' '[:lower:]')
  BOOT_DELAY=$NEW_BOOT_DELAY
  KEEP_ALIVE=$NEW_KEEP_ALIVE
  RETRY_INTERVAL=$NEW_RETRY_INTERVAL
  return 0
}

config_fingerprint() {
  cksum "$CONFIG_FILE" 2>/dev/null | awk '{ print $1 ":" $2 }'
}

read_state() {
  STATE_IFACE=
  STATE_IP_CIDR=
  [ -r "$STATE_FILE" ] || return 0
  STATE_IFACE=$(sed -n '1p' "$STATE_FILE")
  STATE_IP_CIDR=$(sed -n '2p' "$STATE_FILE")
}

write_state() {
  printf '%s\n%s\n' "$1" "$2" > "$STATE_FILE"
  chmod 0600 "$STATE_FILE" 2>/dev/null || true
}

remove_firewall_rule() {
  command -v iptables >/dev/null 2>&1 || return 0
  while iptables -w 2 -C INPUT -j "$CHAIN" >/dev/null 2>&1; do
    iptables -w 2 -D INPUT -j "$CHAIN" >/dev/null 2>&1 || break
  done
  iptables -w 2 -F "$CHAIN" >/dev/null 2>&1 || true
  iptables -w 2 -X "$CHAIN" >/dev/null 2>&1 || true
}

remove_dns_redirect() {
  command -v iptables >/dev/null 2>&1 || return 0
  while iptables -w 2 -t nat -C PREROUTING -j "$DNS_CHAIN" >/dev/null 2>&1; do
    iptables -w 2 -t nat -D PREROUTING -j "$DNS_CHAIN" >/dev/null 2>&1 || break
  done
  iptables -w 2 -t nat -F "$DNS_CHAIN" >/dev/null 2>&1 || true
  iptables -w 2 -t nat -X "$DNS_CHAIN" >/dev/null 2>&1 || true
}

ensure_dns_redirect() {
  IFACE=$1
  ADDRESS=$2
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -w 2 -t nat -N "$DNS_CHAIN" >/dev/null 2>&1 || true
  iptables -w 2 -t nat -C PREROUTING -j "$DNS_CHAIN" >/dev/null 2>&1 ||
    iptables -w 2 -t nat -I PREROUTING 1 -j "$DNS_CHAIN" >/dev/null 2>&1 || return 1
  iptables -w 2 -t nat -F "$DNS_CHAIN" >/dev/null 2>&1 || return 1
  iptables -w 2 -t nat -A "$DNS_CHAIN" -i "$IFACE" -p udp --dport 53 \
    -j DNAT --to-destination "$ADDRESS:$DNS_PORT" >/dev/null 2>&1 || return 1
  iptables -w 2 -t nat -A "$DNS_CHAIN" -i "$IFACE" -p tcp --dport 53 \
    -j DNAT --to-destination "$ADDRESS:$DNS_PORT" >/dev/null 2>&1 || return 1
}

dns_server_running() {
  [ -r "$DNS_PID_FILE" ] || return 1
  DNS_PID=$(sed -n '1p' "$DNS_PID_FILE")
  case "$DNS_PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
  DNS_CMD=$(tr '\000' ' ' < "/proc/$DNS_PID/cmdline" 2>/dev/null)
  case "$DNS_CMD" in
    *HotspotCtl\ dns-server*) kill -0 "$DNS_PID" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

stop_dns_server() {
  if dns_server_running; then
    kill "$DNS_PID" 2>/dev/null || true
    DNS_STOP_WAIT=0
    while kill -0 "$DNS_PID" 2>/dev/null && [ "$DNS_STOP_WAIT" -lt 30 ]; do
      DNS_STOP_WAIT=$((DNS_STOP_WAIT + 1))
      sleep 0.1
    done
    if kill -0 "$DNS_PID" 2>/dev/null; then
      kill -9 "$DNS_PID" 2>/dev/null || true
    fi
  fi
  rm -f "$DNS_PID_FILE"
}

ensure_dns_server() {
  dns_server_running && return 0
  rm -f "$DNS_PID_FILE"
  : > "$DNS_LOG_FILE"
  CLASSPATH="$MODDIR/bin/hotspotctl.dex" \
    app_process /system/bin HotspotCtl dns-server \
      "$IP_ADDRESS" "$DNS_DOMAIN" "$DNS_PORT" >> "$DNS_LOG_FILE" 2>&1 &
  DNS_PID=$!
  printf '%s\n' "$DNS_PID" > "$DNS_PID_FILE"
  chmod 0600 "$DNS_PID_FILE" "$DNS_LOG_FILE" 2>/dev/null || true
  sleep 1
  if dns_server_running; then
    log "DNS server started: $DNS_DOMAIN -> $IP_ADDRESS"
    return 0
  fi
  log "ERROR: DNS server failed to start; see $DNS_LOG_FILE"
  rm -f "$DNS_PID_FILE"
  return 1
}

ensure_firewall_rule() {
  IFACE=$1
  ADDRESS=$2
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -w 2 -N "$CHAIN" >/dev/null 2>&1 || true
  iptables -w 2 -C INPUT -j "$CHAIN" >/dev/null 2>&1 ||
    iptables -w 2 -I INPUT 1 -j "$CHAIN" >/dev/null 2>&1 || return 1
  iptables -w 2 -F "$CHAIN" >/dev/null 2>&1 || return 1
  iptables -w 2 -A "$CHAIN" -i "$IFACE" -d "$ADDRESS" -j ACCEPT >/dev/null 2>&1
}

cleanup_network() {
  stop_dns_server
  remove_dns_redirect
  read_state
  if [ -n "$STATE_IFACE" ] && [ -n "$STATE_IP_CIDR" ] &&
      [ -d "/sys/class/net/$STATE_IFACE" ]; then
    ip address del "$STATE_IP_CIDR" dev "$STATE_IFACE" >/dev/null 2>&1 || true
  fi
  remove_firewall_rule
  rm -f "$STATE_FILE"
}
