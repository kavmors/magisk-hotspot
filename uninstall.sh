#!/system/bin/sh

MODDIR=${0%/*}
RUNDIR=/data/adb/magisk-hotspot

if [ -r "$RUNDIR/daemon.pid" ]; then
  PID=$(sed -n '1p' "$RUNDIR/daemon.pid")
  DAEMON_CMD=
  case "$PID" in
    ''|*[!0-9]*) ;;
    *) DAEMON_CMD=$(tr '\000' ' ' < "/proc/$PID/cmdline" 2>/dev/null) ;;
  esac
  case "$DAEMON_CMD" in
    *magisk-hotspot/scripts/daemon.sh*) kill "$PID" 2>/dev/null || true ;;
  esac
fi

if [ -x "$MODDIR/scripts/hotspot.sh" ]; then
  "$MODDIR/scripts/hotspot.sh" cleanup >/dev/null 2>&1 || true
fi

rm -rf "$RUNDIR"
