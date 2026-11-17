#!/bin/bash
# Vygeneruje Xcode projekt pro iPhone a otevře ho.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen
if [[ -d /Applications/Xcode-beta.app ]]; then open -a Xcode-beta Stahovak.xcodeproj; else open Stahovak.xcodeproj; fi
