#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
mkdir -p .build/module-cache
swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -module-cache-path .build/module-cache \
  Sources/InputBridge/SpeechModelSelection.swift Sources/InputBridge/TextMessage.swift Sources/InputBridge/ScreenSharingMonitor.swift \
  Sources/InputBridge/TargetResolver.swift Sources/InputBridge/SendBacklog.swift Sources/InputBridge/TextTransport.swift \
  Tests/TransportSmoke.swift -o .build/TransportSmoke
.build/TransportSmoke
