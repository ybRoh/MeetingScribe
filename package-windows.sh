#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
version="$(cat VERSION)"
dotnet="${DOTNET:-dotnet}"
stage="$(mktemp -d "${TMPDIR:-/tmp}/meetingscribe-win.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
folder="$stage/MeetingScribe"
downloads="$root/dist/windows-downloads"
mkdir -p "$folder" "$downloads"
./setup-models.sh

download_engine() {
  local file="$downloads/$1.zip" url="$2" hash="$3"
  if [[ ! -f "$file" ]]; then
    curl --fail --location --retry 2 "$url" --output "$file.part"
    printf '%s  %s\n' "$hash" "$file.part" | shasum -a 256 -c -
    mv "$file.part" "$file"
  fi
  printf '%s  %s\n' "$hash" "$file" | shasum -a 256 -c -
}
download_engine whisper https://github.com/ggml-org/whisper.cpp/releases/download/b5907/whisper-bin-x64.zip \
  ecca07b277d943e9b9f4712856a144b857271a6b333104e511e1988e80db582b
download_engine llama https://github.com/ggml-org/llama.cpp/releases/download/b12804/llama-b12804-bin-win-cpu-x64.zip \
  62d49f13f25064246c9df13291f92060d80b490018fcef805899ebc9ef0456b5

"$dotnet" publish Windows/MeetingScribe.csproj -c Release -r win-x64 --self-contained true -o "$folder"
mkdir -p "$folder/engines/whisper" "$folder/engines/llama" "$folder/models" "$folder/ThirdPartyLicenses"
unzip -qj "$downloads/whisper.zip" 'Release/whisper-cli.exe' 'Release/whisper.dll' 'Release/ggml*.dll' -d "$folder/engines/whisper"
unzip -qj "$downloads/llama.zip" 'llama-completion.exe' 'llama-completion-impl.dll' 'llama.dll' 'llama-common.dll' 'ggml*.dll' 'libomp.dll' -d "$folder/engines/llama"
unzip -p "$downloads/llama.zip" LICENSE-LLVM-OpenMP > "$folder/ThirdPartyLicenses/libomp.txt"
for name in whisper.cpp ggml llama.cpp NAudio OpenAI-Whisper Qwen3; do
  cp "licenses/$name.txt" "$folder/ThirdPartyLicenses/"
done
for name in ggml-large-v3-turbo-q5_0.bin Qwen3-4B-Q4_K_M.gguf; do
  ln "$root/dist/models/$name" "$folder/models/$name" || cp "$root/dist/models/$name" "$folder/models/$name"
done

cat > "$folder/사용 안내.txt" <<GUIDE
회의록 서기 $version · Windows x64 (Intel / AMD)
Windows 11 x64 환경에서 ZIP 전체를 풀고 MeetingScribe.exe를 실행하세요.
Microsoft Visual C++ Redistributable x64가 필요합니다.
설치되어 있지 않다면 공식 설치 파일을 사용하세요. https://aka.ms/vc14/vc_redist.x64.exe

1. 참석자 동의 확인에 체크하고 기록 시작을 누릅니다.
2. 기록 종료를 누르면 한국어 받아쓰기와 회의록 생성을 차례로 진행합니다.
3. 회의록 하단 To-Do List를 확인하고 내용을 편집·복사하거나 Markdown으로 저장합니다.

Windows판은 대면 회의 마이크 녹음을 지원합니다. 받아쓰기는 녹음 종료 후 시작합니다.
모델과 .NET 런타임이 포함되어 있습니다. 회의 내용은 PC에서 처리합니다.
Windows판은 실패한 녹음을 보관합니다. 성공하면 회의록을 자동 보관한 뒤 처리용 WAV를 삭제합니다.
앱은 코드 서명되지 않았으며 실제 Windows PC에서 마이크 동작 확인이 필요합니다.
GUIDE
(
  cd "$stage"
  python3 - "$version" <<'PYZIP'
from pathlib import Path
import sys
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

with ZipFile(f'MeetingScribe-{sys.argv[1]}-Windows-x64.zip', 'w') as archive:
    for file in sorted(Path('MeetingScribe').rglob('*')):
        if file.is_file() and file.suffix != '.pdb':
            method = ZIP_STORED if file.parent.name == 'models' else ZIP_DEFLATED
            archive.write(file, compress_type=method, compresslevel=3)
PYZIP
)
unzip -tq "$stage/MeetingScribe-$version-Windows-x64.zip"
mv "$stage/MeetingScribe-$version-Windows-x64.zip" "$root/dist/"
