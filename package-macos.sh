#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
version="$(cat VERSION)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/meetingscribe-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/image/회의록 서기.app"
archive="$stage/MeetingScribe-$version-macOS-arm64.zip"
signature="${SCRIBE_CODESIGN_IDENTITY:--}"
sign_options=()
if [[ "$signature" != "-" ]]; then sign_options=(--options runtime); fi
mkdir -p "$stage/image"
./setup-models.sh
SCRIBE_APP_PATH="$app" ./build.sh

python3 - "$app" <<'PY'
import os
import shutil
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir()
main = app / 'Contents/MacOS/MeetingScribe'
prefixes = [Path(os.environ.get(key, default)) for key, default in (
    ('WHISPER_PREFIX', '/opt/homebrew/opt/whisper.cpp'),
    ('GGML_PREFIX', '/opt/homebrew/opt/ggml'),
    ('LLAMA_PREFIX', '/opt/homebrew/opt/llama.cpp'),
)]

def run(*args):
    return subprocess.check_output(args, text=True)

def bundle(source):
    target = frameworks / source.name
    if not target.exists():
        shutil.copy2(source, target)
        target.chmod(0o755)
    return target

def linked_paths(binary):
    return [line.strip().split(' (', 1)[0] for line in run('otool', '-L', binary).splitlines()[1:]]

helper = bundle(prefixes[2] / 'bin/llama-server')
plugins = [bundle(path) for path in sorted((prefixes[1] / 'libexec').glob('libggml-*.so'))]
queue = [main, helper, *plugins]
seen = set()
while queue:
    binary = queue.pop()
    if binary in seen:
        continue
    seen.add(binary)
    dependencies = linked_paths(binary)
    if binary.suffix == '.dylib':
        run('install_name_tool', '-id', f'@loader_path/{binary.name}', binary)
        dependencies = dependencies[1:]
    for path in dependencies:
        if path.startswith(('/System/Library/', '/usr/lib/')):
            continue
        if path.startswith('@rpath/'):
            candidates = [prefix / 'lib' / Path(path).name for prefix in prefixes]
            source = next((item for item in candidates if item.is_file()), None)
        elif path.startswith('/'):
            source = Path(path)
        else:
            raise RuntimeError(f'Unexpected dependency {path} in {binary.name}')
        if not source or not source.is_file():
            raise FileNotFoundError(path)
        dependency = bundle(source)
        queue.append(dependency)
        relative = '@loader_path/../Frameworks' if binary == main else '@loader_path'
        run('install_name_tool', '-change', path, f'{relative}/{source.name}', binary)
    lines = run('otool', '-l', binary).splitlines()
    for i, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            rpath = lines[i + 2].strip().removeprefix('path ').split(' (offset', 1)[0]
            run('install_name_tool', '-delete_rpath', rpath, binary)

# GGML searches its compiled-in Homebrew directory before the helper directory.
# Disable that fallback so the signed release always loads its bundled plugins.
ggml = frameworks / 'libggml.1.dylib'
homebrew_backends = os.fsencode((prefixes[1] / 'libexec').resolve()) + b'\0'
contents = ggml.read_bytes()
if contents.count(homebrew_backends) != 1:
    raise RuntimeError('Could not identify the compiled-in GGML backend directory')
ggml.write_bytes(contents.replace(homebrew_backends, b'/dev/null\0'.ljust(len(homebrew_backends), b'\0')))

models = app / 'Contents/Resources/models'
models.mkdir(parents=True)
for name in ('ggml-large-v3-turbo-q5_0.bin', 'Qwen3-4B-Q4_K_M.gguf'):
    dest = models / name
    try:
        os.link(Path('dist/models') / name, dest)
    except OSError:
        shutil.copyfile(Path('dist/models') / name, dest)
PY

mkdir -p "$app/Contents/Resources/ThirdPartyLicenses"
for name in whisper.cpp ggml llama.cpp libomp OpenSSL OpenAI-Whisper Qwen3; do
  cp "licenses/$name.txt" "$app/Contents/Resources/ThirdPartyLicenses/"
done
for binary in "$app/Contents/Frameworks/"*; do
  codesign --force --sign "$signature" ${sign_options[@]+"${sign_options[@]}"} "$binary"
done
codesign --force --sign "$signature" ${sign_options[@]+"${sign_options[@]}"} "$app"
codesign --verify --strict --deep "$app"
"$app/Contents/Frameworks/llama-server" --version
cat > "$stage/image/사용 안내.txt" <<GUIDE
회의록 서기 $version · Apple Silicon
ZIP을 풀고 회의록 서기 앱을 응용 프로그램 폴더로 옮긴 뒤 실행하세요.
참석자 동의를 확인하고 기록 시작을 누른 뒤 마이크 접근을 허용하세요.
기록 종료 후 회의록과 하단 To-Do List를 편집하거나 복사하고 Markdown으로 저장할 수 있습니다.
두 AI 모델과 실행 엔진이 포함되어 있으며 회의 내용은 Mac에서 처리합니다.
검증 환경은 macOS 27.0.1입니다. Apple Developer ID 서명 및 공증은 적용되지 않았습니다.
GUIDE
ditto -c -k --sequesterRsrc "$stage/image" "$archive"
unzip -tq "$archive"
mv "$archive" "$root/dist/MeetingScribe-$version-macOS-arm64.zip"
