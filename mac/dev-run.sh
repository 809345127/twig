#!/bin/bash
# 开发用：编译 + 打包成 .app + 重启。
# 裸可执行文件不是正经 App（系统当它是后台辅助程序，没有 Dock 图标、
# tell application 都找不到它，窗口位置也可能不对）——必须包一层 .app 壳，
# 跟 Go 那边 packaging/make-app.sh 的道理一样。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c debug

APP="/tmp/TwigMac-dev.app"
pkill -f "$APP/Contents/MacOS/TwigMac" 2>/dev/null || true
sleep 0.3
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/arm64-apple-macosx/debug/TwigMac "$APP/Contents/MacOS/TwigMac"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TwigMac</string>
  <key>CFBundleIdentifier</key><string>dev.twig.TwigMac</string>
  <key>CFBundleName</key><string>TwigMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF
open "$APP"
echo "started: $APP"
