#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
models_dir="${1:-dist/models}"
mkdir -p "$models_dir"

download_model() {
  local name="$1" address="$2" hash="$3" kind="$4" bytes="$5"
  local file="$models_dir/$name"
  if [[ -f "$file" ]] && printf '%s  %s\n' "$hash" "$file" | shasum -a "$kind" -c -; then
    return
  fi
  if [[ ! -f "$file.part" ]] || ! printf '%s  %s\n' "$hash" "$file.part" | shasum -a "$kind" -c - >/dev/null 2>&1; then
    if [[ -f "$file.part" && $(wc -c < "$file.part") -ge "$bytes" ]]; then rm -f "$file.part"; fi
    local result=0
    curl --fail --location --retry 2 --continue-at - "$address" --output "$file.part" || result=$?
    if [[ "$result" -eq 33 || "$result" -eq 36 ]]; then
      rm -f "$file.part"
      curl --fail --location --retry 2 "$address" --output "$file.part"
    elif [[ "$result" -ne 0 ]]; then
      return "$result"
    fi
    if ! printf '%s  %s\n' "$hash" "$file.part" | shasum -a "$kind" -c -; then
      rm -f "$file.part"
      return 1
    fi
  fi
  mv "$file.part" "$file"
}

download_model ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin \
  e050f7970618a659205450ad97eb95a18d69c9ee 1 574041195
download_model Qwen3-4B-Q4_K_M.gguf \
  https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf \
  7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5 256 2497280256
