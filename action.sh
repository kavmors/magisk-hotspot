#!/system/bin/sh

MODDIR=${0%/*}

exec "$MODDIR/scripts/hotspot.sh" apply
