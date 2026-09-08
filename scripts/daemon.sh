#!/system/bin/sh

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
. "$MODDIR/scripts/common.sh"

LOCKDIR="$RUNDIR/daemon.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  OLD_PID=$(sed -n '1p' "$RUNDIR/daemon.pid" 2>/dev/null)
  OLD_CMD=
  case "$OLD_PID" in
    ''|*[!0-9]*) ;;
    *) OLD_CMD=$(tr '\000' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null) ;;
  esac
  case "$OLD_CMD" in
    *magisk-hotspot/scripts/daemon.sh*) exit 0 ;;
  esac
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || exit 1
fi

printf '%s\n' "$$" > "$RUNDIR/daemon.pid"
cleanup_daemon_lock() {
  rm -f "$RUNDIR/daemon.pid"
  rmdir "$LOCKDIR" 2>/dev/null || true
}
trap cleanup_daemon_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

until [ "$(getprop sys.boot_completed)" = 1 ]; do
  sleep 2
done

load_config || exit 1
sleep "$BOOT_DELAY"

FINGERPRINT=
ACTIVE=false
START_ATTEMPTED=false
MISSES=0
while true; do
  if ! load_config; then
    log "WARN: config.yml is invalid; daemon will retry"
    sleep 3
    continue
  fi
  CURRENT_FINGERPRINT=$(config_fingerprint)

  if [ -z "$SSID" ]; then
    if [ "$ACTIVE" = true ] || [ "$START_ATTEMPTED" = true ]; then
      "$MODDIR/scripts/hotspot.sh" stop
      log "hotspot stopped because hotspot.ssid is empty"
    fi
    ACTIVE=false
    START_ATTEMPTED=false
    FINGERPRINT=$CURRENT_FINGERPRINT
    MISSES=0
    sleep 3
    continue
  fi

  if [ "$ACTIVE" != true ] || [ "$CURRENT_FINGERPRINT" != "$FINGERPRINT" ]; then
    START_ATTEMPTED=true
    FINGERPRINT=$CURRENT_FINGERPRINT
    if "$MODDIR/scripts/hotspot.sh" apply; then
      load_config || true
      ACTIVE=true
      MISSES=0
      log "configuration applied"
    else
      ACTIVE=false
      log "WARN: hotspot start failed; daemon will retry"
    fi
    sleep "$RETRY_INTERVAL"
    continue
  fi

  if "$MODDIR/scripts/hotspot.sh" ensure-ip; then
    MISSES=0
  else
    MISSES=$((MISSES + 1))
    if [ "$KEEP_ALIVE" = true ] && [ "$MISSES" -ge 3 ]; then
      log "hotspot unavailable; attempting restart"
      ACTIVE=false
      MISSES=0
    fi
  fi
  sleep "$RETRY_INTERVAL"
done
