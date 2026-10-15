#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p .build/module-cache
sources=(Sources/InputBridge/*.swift)
sources=(${sources:#Sources/InputBridge/InputBridgeApp.swift})
TEST_NAME=SpeechStartupSmoke
if [[ "${1:-}" == "--apple" ]]; then
  TEST_NAME=AppleSpeechWarmSmoke
elif (( $# > 0 )); then
  print -u2 "用法：zsh Scripts/test-speech-startup.sh [--apple]"
  exit 2
fi
swiftc -D DEBUG -parse-as-library -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -module-cache-path .build/module-cache "${sources[@]}" \
  "Tests/$TEST_NAME.swift" -o ".build/$TEST_NAME"
".build/$TEST_NAME"
