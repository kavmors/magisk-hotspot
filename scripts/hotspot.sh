#!/system/bin/sh

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
. "$MODDIR/scripts/common.sh"

run_ctl() {
  CLASSPATH="$MODDIR/bin/hotspotctl.dex" app_process /system/bin HotspotCtl "$@"
}

configure_hotspot() {
  OUTPUT=$(run_ctl configure "$SSID" "$PASSWORD" "$BAND_ARG" 2>&1)
  STATUS=$?
  log "hotspotctl configure: $OUTPUT"
  return "$STATUS"
}

start_hotspot() {
  if [ -z "$SSID" ]; then
    log "hotspot not started because hotspot.ssid is empty"
    return 0
  fi
  if configure_hotspot; then
    OUTPUT=$(run_ctl start 2>&1)
    STATUS=$?
    log "hotspotctl start: $OUTPUT"
    [ "$STATUS" -eq 0 ] && return 0
  else
    log "WARN: failed to save hotspot configuration through the framework API"
  fi

  # Some vendor ROMs restrict the framework tethering call but keep AOSP's
  # privileged Wi-Fi shell command. This fallback still provides SoftAP mode.
  if [ -n "$PASSWORD" ]; then
    OUTPUT=$(cmd wifi start-softap "$SSID" wpa2 "$PASSWORD" -b "$BAND_ARG" 2>&1)
  else
    OUTPUT=$(cmd wifi start-softap "$SSID" open -b "$BAND_ARG" 2>&1)
  fi
  STATUS=$?
  log "cmd wifi fallback: $OUTPUT"
  return "$STATUS"
}

stop_hotspot() {
  run_ctl stop >/dev/null 2>&1 || cmd wifi stop-softap >/dev/null 2>&1 || true
}

find_hotspot_interface() {
  IFACE=$(dumpsys wifi 2>/dev/null | awk '
    /mApInterfaceName:/ {
      name = $2
      gsub(/[,}]/, "", name)
      if (name != "" && name != "null") { print name; exit }
    }
  ')
  if [ -n "$IFACE" ] && [ -d "/sys/class/net/$IFACE" ]; then
    printf '%s\n' "$IFACE"
    return 0
  fi

  DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')
  ip -o -4 addr show up scope global 2>/dev/null | awk -v default_iface="$DEFAULT_IFACE" '
    {
      iface = $2
      address = $4
      sub(/\/.*/, "", address)
      split(address, octet, ".")
      is_private = octet[1] == 10 ||
        (octet[1] == 172 && octet[2] >= 16 && octet[2] <= 31) ||
        (octet[1] == 192 && octet[2] == 168)
      if (iface != default_iface && is_private && octet[4] == 1 &&
          iface ~ /^(ap|wlan|swlan|wifi|softap)/) {
        print iface
        exit
      }
    }
  '
}

find_interface_ipv4() {
  ip -o -4 addr show dev "$1" scope global 2>/dev/null |
    awk 'NR == 1 { address = $4; sub(/\/.*/, "", address); print address; exit }'
}

ensure_stable_ip() {
  [ -n "$SSID" ] || return 1
  IFACE=$(find_hotspot_interface)
  if [ -z "$IFACE" ]; then
    set_module_inactive_description || true
    return 1
  fi

  if [ -n "$IP_CIDR" ]; then
    if ! ip -o -4 addr show dev "$IFACE" 2>/dev/null |
        awk '{ address = $4; sub(/\/.*/, "", address); print address }' |
        grep -Fx "$IP_ADDRESS" >/dev/null 2>&1; then
      ip address add "$IP_CIDR" dev "$IFACE" || return 1
      log "added $IP_CIDR to $IFACE"
    fi
    DNS_ADDRESS=$IP_ADDRESS
    ensure_firewall_rule "$IFACE" "$IP_ADDRESS" ||
      log "WARN: could not install IPv4 INPUT allow rule"
  else
    DNS_ADDRESS=$(find_interface_ipv4 "$IFACE")
  fi
  if [ -z "$DNS_ADDRESS" ]; then
    set_module_inactive_description || true
    return 1
  fi
  set_module_running_description "$DNS_ADDRESS" "$DNS_DOMAIN" ||
    log "WARN: could not update module description"

  if [ -n "$DNS_DOMAIN" ]; then
    ensure_firewall_rule "$IFACE" "$DNS_ADDRESS" ||
      log "WARN: could not install IPv4 INPUT allow rule"
    ensure_dns_server || return 1
    ensure_dns_redirect "$IFACE" "$DNS_ADDRESS" || {
      log "ERROR: could not redirect hotspot DNS traffic"
      stop_dns_server
      remove_dns_redirect
      return 1
    }
  else
    stop_dns_server
    remove_dns_redirect
  fi
  write_state "$IFACE" "$IP_CIDR"
  return 0
}

apply_config() {
  load_config || return 1
  if [ -z "$SSID" ]; then
    cleanup_network
    stop_hotspot
    log "hotspot disabled because hotspot.ssid is empty"
    return 0
  fi
  cleanup_network
  stop_hotspot

  STOP_WAIT=0
  while find_hotspot_interface >/dev/null 2>&1 && [ "$STOP_WAIT" -lt 10 ]; do
    STOP_WAIT=$((STOP_WAIT + 1))
    sleep 1
  done
  start_hotspot || return 1

  ATTEMPT=0
  while [ "$ATTEMPT" -lt 15 ]; do
    ensure_stable_ip && return 0
    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
  done
  log "ERROR: hotspot interface did not become ready"
  return 1
}

case "$1" in
  apply)
    OPERATION_LOCK="$RUNDIR/operation.lock"
    if ! mkdir "$OPERATION_LOCK" 2>/dev/null; then
      OPERATION_PID=$(sed -n '1p' "$OPERATION_LOCK/pid" 2>/dev/null)
      OPERATION_CMD=
      case "$OPERATION_PID" in
        ''|*[!0-9]*) ;;
        *) OPERATION_CMD=$(tr '\000' ' ' < "/proc/$OPERATION_PID/cmdline" 2>/dev/null) ;;
      esac
      case "$OPERATION_CMD" in
        *hotspot.sh*)
          log "WARN: another configuration operation is already running"
          exit 1
          ;;
        *)
          rm -rf "$OPERATION_LOCK"
          mkdir "$OPERATION_LOCK" 2>/dev/null || exit 1
          ;;
      esac
    fi
    printf '%s\n' "$$" > "$OPERATION_LOCK/pid"
    cleanup_operation_lock() {
      rm -f "$OPERATION_LOCK/pid"
      rmdir "$OPERATION_LOCK" 2>/dev/null || true
    }
    trap cleanup_operation_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if apply_config; then
      log "configuration applied successfully"
      exit 0
    fi
    exit 1
    ;;
  start)
    load_config && start_hotspot
    ;;
  ensure-ip)
    load_config && ensure_stable_ip
    ;;
  stop)
    cleanup_network
    stop_hotspot
    ;;
  cleanup)
    cleanup_network
    ;;
  *)
    printf 'Usage: %s {apply|start|ensure-ip|stop|cleanup}\n' "$0" >&2
    exit 2
    ;;
esac
