#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [1/4] Compilazione MacHost in modalità Release Universal (arm64 + x86_64) ==="
swift build -c release --arch arm64 --arch x86_64

APP_NAME="MacHost.app"
APP_DIR="$SCRIPT_DIR/build/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo "=== [2/4] Creazione Bundle $APP_NAME ==="
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$FRAMEWORKS_DIR"

# Trova il binario finale compilato (escludendo gli intermedi monolitici arm64/x86_64)
if [ -f ".build/out/Products/Release/MacHost" ]; then
    BUILD_BIN=".build/out/Products/Release/MacHost"
elif [ -f ".build/apple/Products/Release/MacHost" ]; then
    BUILD_BIN=".build/apple/Products/Release/MacHost"
else
    BUILD_BIN=$(find .build -path "*/Products/Release/MacHost" -type f -perm +111 | head -n 1)
    if [ -z "$BUILD_BIN" ]; then
        BUILD_BIN=$(find .build -name "MacHost" -type f -perm +111 | grep -v "Intermediates" | head -n 1)
    fi
fi

echo "-> Binario selezionato: $BUILD_BIN"
lipo -info "$BUILD_BIN"

cp "$BUILD_BIN" "$MACOS_DIR/MacHost"
cp Info.plist "$CONTENTS_DIR/Info.plist"

# Includi ice_servers.json (se presente localmente) nella cartella Resources del bundle
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$RESOURCES_DIR"
if [ -f "$SCRIPT_DIR/ice_servers.json" ]; then
    cp "$SCRIPT_DIR/ice_servers.json" "$RESOURCES_DIR/ice_servers.json"
    echo "-> ice_servers.json copiato in $RESOURCES_DIR"
elif [ -f "$SCRIPT_DIR/../ice_servers.json" ]; then
    cp "$SCRIPT_DIR/../ice_servers.json" "$RESOURCES_DIR/ice_servers.json"
    echo "-> ice_servers.json copiato in $RESOURCES_DIR"
fi

echo "=== [3/4] Inclusione WebRTC.framework nel bundle ==="
cp -R "Frameworks/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework" "$FRAMEWORKS_DIR/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/MacHost" 2>/dev/null || true

echo "=== [4/4] Firma del bundle (Ad-Hoc con Entitlements e Bundle ID fisso) ==="
xattr -cr "$APP_DIR" || true
codesign --force --sign - "$FRAMEWORKS_DIR/WebRTC.framework"
codesign --force --deep --sign - -i "com.desktopremoting.host" --entitlements Host.entitlements "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "=========================================================="
echo "Applicazione creata con successo in:"
echo "   $APP_DIR"
lipo -info "$MACOS_DIR/MacHost"
echo "Puoi avviarla con: open $APP_DIR"
echo "=========================================================="
