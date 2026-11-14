#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Pulsar.app
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Pulsar</string>
<key>CFBundleIdentifier</key><string>com.tamcut.Pulsar</string>
<key>CFBundleName</key><string>Pulsar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.4</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>선택한 Mac과 암호화된 화면 및 입력 연결을 만듭니다.</string>
<key>NSScreenCaptureUsageDescription</key><string>연결한 Mac에 화면을 공유합니다.</string>
</dict></plist>
PLIST
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -framework AppKit -framework ScreenCaptureKit -framework Network -framework Security -framework ApplicationServices -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework AVFoundation -framework Carbon -framework ServiceManagement -framework IOKit Protocol.swift Capture.swift App.swift Pages.swift Permissions.swift Tests.swift main.swift -o "$APP/Contents/MacOS/Pulsar"
codesign --force --sign - "$APP"
/bin/bash scripts/clear-quarantine.sh "$APP"
codesign --verify --strict "$APP"
echo "BUILD PASS $PWD/$APP"
