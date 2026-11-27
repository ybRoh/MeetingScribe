#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash setup-models.sh "$PWD/models"
open "$PWD/회의록 서기.app"
