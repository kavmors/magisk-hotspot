#!/system/bin/sh

ui_print "- Installing Magisk Hotspot"

if [ "$API" -lt 29 ]; then
  abort "! Android 10 (API 29) or newer is required"
fi

OLD_CONFIG="/data/adb/modules/magisk-hotspot/config.yml"
if [ -f "$OLD_CONFIG" ]; then
  ui_print "- Preserving existing config.yml"
  cp -af "$OLD_CONFIG" "$MODPATH/config.yml"
fi

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/bin/hotspotctl.dex" 0 0 0644
set_perm "$MODPATH/config.yml" 0 0 0600

ui_print "- Edit $MODPATH/config.yml, then reboot"
