#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="${SCRIBE_APP_PATH:-$PWD/dist/회의록 서기.app}"
whisper="${WHISPER_PREFIX:-/opt/homebrew/opt/whisper.cpp}"
ggml="${GGML_PREFIX:-/opt/homebrew/opt/ggml}"
if [[ ! -r "$whisper/include/whisper.h" ]]; then
  echo 'whisper.cpp를 설치하세요. brew install whisper.cpp' >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$PWD/dist/module-cache"
cp Info.plist "$app/Contents/Info.plist"
xcrun clang -O2 -mmacosx-version-min=26.0 -I "$whisper/include" -I "$ggml/include" "-DSCRIBE_GGML_BACKENDS=\"$ggml/libexec\"" -c Sources/WhisperBridge.c -o dist/WhisperBridge.o
xcrun swiftc -module-cache-path "$PWD/dist/module-cache" -swift-version 6 -O -target arm64-apple-macosx26.0 \
  -import-objc-header Sources/WhisperBridge.h -L "$whisper/lib" -lwhisper -L "$ggml/lib" -lggml \
  -Xlinker -rpath -Xlinker "$whisper/lib" Sources/*.swift dist/WhisperBridge.o -o "$app/Contents/MacOS/MeetingScribe"
/usr/bin/codesign --force --sign - "$app"
echo "$app"
