#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
umask 077
bash setup-models.sh "$HOME/Library/Application Support/MeetingScribe/Models"
open "$PWD/회의록 서기.app"
