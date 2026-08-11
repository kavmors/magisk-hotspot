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

FINGERPRINT=$(config_fingerprint)
if "$MODDIR/scripts/hotspot.sh" apply; then
  log "boot configuration applied"
else
  log "WARN: initial hotspot start failed; daemon will retry"
fi

MISSES=0
while true; do
  sleep "$RETRY_INTERVAL"

  CURRENT_FINGERPRINT=$(config_fingerprint)
  if [ -n "$CURRENT_FINGERPRINT" ] && [ "$CURRENT_FINGERPRINT" != "$FINGERPRINT" ]; then
    if "$MODDIR/scripts/hotspot.sh" apply; then
      FINGERPRINT=$CURRENT_FINGERPRINT
      load_config || true
      MISSES=0
      log "reloaded changed config.yml"
    else
      log "WARN: changed config.yml is invalid or could not be applied"
    fi
    continue
  fi

  if "$MODDIR/scripts/hotspot.sh" ensure-ip; then
    MISSES=0
    continue
  fi

  MISSES=$((MISSES + 1))
  if [ "$KEEP_ALIVE" = true ] && [ "$MISSES" -ge 3 ]; then
    log "hotspot unavailable; attempting restart"
    "$MODDIR/scripts/hotspot.sh" apply || true
    MISSES=0
  fi
done
