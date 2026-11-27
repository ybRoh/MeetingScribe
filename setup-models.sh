#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
models_dir="${1:-dist/models}"
mkdir -p "$models_dir"

download_model() {
  local name="$1" address="$2" hash="$3" kind="$4"
  local file="$models_dir/$name"
  if [[ -f "$file" ]] && printf '%s  %s\n' "$hash" "$file" | shasum -a "$kind" -c -; then
    return
  fi
  curl --fail --location --retry 2 "$address" --output "$file.part"
  printf '%s  %s\n' "$hash" "$file.part" | shasum -a "$kind" -c -
  mv "$file.part" "$file"
}

download_model ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin \
  e050f7970618a659205450ad97eb95a18d69c9ee 1
download_model Qwen3-4B-Q4_K_M.gguf \
  https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf \
  7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5 256
