#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
version=1.1.0
stage="$(mktemp -d "${TMPDIR:-/tmp}/scribe-public.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
output="$root/dist/public"
mkdir -p "$output" "$stage/mac/MeetingScribe" "$stage/win"
mac="$stage/mac/MeetingScribe"
windows="$stage/win/MeetingScribe"

ditto -x -k "dist/MeetingScribe-$version-macOS-arm64.zip" "$mac"
app="$mac/회의록 서기.app"
rm -rf "$app/Contents/Resources/models"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
cp setup-models.sh release/Setup-Mac.command "$mac/"
cat > "$mac/사용 안내.txt" <<'GUIDE'
회의록 서기 1.1.0 · Apple Silicon Mac
1. ZIP을 풀고 MeetingScribe 폴더를 원하는 위치에 둡니다.
2. 처음 한 번 Setup-Mac.command를 실행하면 AI 모델(약 3 GB)을 받은 뒤 앱이 열립니다.
   Finder에서 스크립트 실행이 차단되면 터미널에 bash와 공백을 입력한 뒤 Setup-Mac.command를
   터미널 창으로 드래그하고 Return을 누르세요.
3. 이후에는 같은 폴더 안의 회의록 서기.app을 실행합니다. 폴더를 통째로 이동하면 모델도 이동합니다.
Apple Developer ID 서명과 공증이 적용되지 않았습니다. 테스트 환경은 macOS 27.0.1입니다.
GUIDE
ditto -c -k --sequesterRsrc --keepParent "$mac" "$stage/MeetingScribe-$version-macOS-arm64.zip"

unzip -q "dist/MeetingScribe-$version-Windows-x64.zip" -x 'MeetingScribe/models/*' -d "$stage/win"
cp release/Setup-Windows.cmd "$windows/"
cat > "$windows/사용 안내.txt" <<'GUIDE'
회의록 서기 1.1.0 · Windows 11 x64
1. ZIP 전체의 압축을 풉니다. Microsoft Visual C++ Redistributable x64가 없다면 설치하세요.
   https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist
2. 처음 한 번 Setup-Windows.cmd를 실행하면 AI 모델(약 3 GB)을 받은 뒤 앱이 열립니다.
3. 이후에는 같은 폴더 안의 MeetingScribe.exe를 실행합니다.
대면 회의를 녹음하고, 기록 종료 후 한국어 받아쓰기와 회의록 생성을 진행합니다.
앱에 코드 서명이 적용되지 않았으며 실제 Windows PC에서 마이크 동작은 검증 전입니다.
GUIDE
python3 - "$stage" "$version" <<'PY'
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import sys

stage = Path(sys.argv[1])
version = sys.argv[2]
root = stage / 'win'
with ZipFile(stage / f'MeetingScribe-{version}-Windows-x64.zip', 'w', ZIP_DEFLATED, compresslevel=3) as archive:
    for file in sorted(root.rglob('*')):
        if file.is_file():
            archive.write(file, file.relative_to(root))
PY

for zip in "$stage/"*.zip; do
    unzip -tq "$zip"
    mv "$zip" "$output/"
done
