#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export JAVA_HOME="/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

echo "=== [1/2] Compilazione APK Android Debug (Gradle 8.7 + AGP 8.3 + WebRTC) ==="
./gradlew assembleDebug

APK_PATH="$SCRIPT_DIR/app/build/outputs/apk/debug/app-debug.apk"

echo "=== [2/2] Verifica completata ==="
if [ -f "$APK_PATH" ]; then
    echo "=========================================================="
    echo "APK generato con successo in:"
    echo "   $APK_PATH"
    echo ""
    echo "Per installarlo su un dispositivo Android collegato via USB:"
    echo "   adb install -r $APK_PATH"
    echo "=========================================================="
else
    echo "Errore: APK non trovato!"
    exit 1
fi
