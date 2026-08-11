#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_ROOT=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}
ANDROID_JAR="$SDK_ROOT/platforms/android-29/android.jar"
BUILD_TOOLS="$SDK_ROOT/build-tools"
JAVAC=${JAVAC:-}

if [ ! -f "$ANDROID_JAR" ]; then
  echo "Android SDK platform 29 was not found at $ANDROID_JAR" >&2
  exit 1
fi

if [ -z "$JAVAC" ]; then
  for candidate in \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/javac" \
    "/Applications/IntelliJ IDEA.app/Contents/jbr/Contents/Home/bin/javac"; do
    if [ -x "$candidate" ]; then
      JAVAC=$candidate
      break
    fi
  done
fi
if [ -z "$JAVAC" ]; then
  JAVAC=$(command -v javac || true)
fi
if [ -z "$JAVAC" ] || [ ! -x "$JAVAC" ]; then
  echo "javac was not found; set JAVAC to a JDK 8+ compiler" >&2
  exit 1
fi

if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME=${JAVAC%/bin/javac}
  export JAVA_HOME
fi

D8=$(find "$BUILD_TOOLS" -maxdepth 2 -type f -name d8 2>/dev/null | sort -V | tail -1)
if [ -z "$D8" ]; then
  echo "d8 was not found below $BUILD_TOOLS" >&2
  exit 1
fi

BUILD="$ROOT/build/hotspotctl"
rm -rf "$BUILD"
mkdir -p "$BUILD/stubs" "$BUILD/classes" "$BUILD/dex" "$ROOT/bin"

"$JAVAC" -source 8 -target 8 -Xlint:-options \
  -classpath "$ANDROID_JAR" \
  -d "$BUILD/stubs" \
  "$ROOT/tools/stubs/android/net/ConnectivityManager.java"

"$JAVAC" -source 8 -target 8 -Xlint:-options \
  -classpath "$BUILD/stubs:$ANDROID_JAR" \
  -d "$BUILD/classes" \
  "$ROOT/tools/src/DnsMessage.java" \
  "$ROOT/tools/src/DnsServer.java" \
  "$ROOT/tools/src/HotspotCtl.java"

"$D8" --min-api 29 --lib "$ANDROID_JAR" --lib "$BUILD/stubs" \
  --output "$BUILD/dex" \
  "$BUILD/classes/DnsMessage.class" "$BUILD/classes/DnsMessage"\$*.class \
  "$BUILD/classes/DnsServer.class" "$BUILD/classes/DnsServer"\$*.class \
  "$BUILD/classes/HotspotCtl.class" "$BUILD/classes/HotspotCtl"\$*.class

cp "$BUILD/dex/classes.dex" "$ROOT/bin/hotspotctl.dex"
echo "Built $ROOT/bin/hotspotctl.dex"
