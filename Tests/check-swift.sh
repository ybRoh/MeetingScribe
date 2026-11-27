#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
folder="$(mktemp -d "${TMPDIR:-/tmp}/scribe-swift-tests.XXXXXX")"
trap 'rm -rf "$folder"' EXIT
swiftc -module-cache-path "$folder/cache" -swift-version 6 Sources/{ToDoList,Utterance,MeetingRecovery,TranscriptSimilarity,SpeechSegmenter,MinutesBatches}.swift Tests/Check.swift -o "$folder/check"
"$folder/check"
