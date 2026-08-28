#!/bin/bash
# 把原生外壳打包成 macOS 的 TwigMac.app —— 双击就能用，不必回终端 swift run。
#
# ⚠️ 跟仓库根目录 packaging/make-app.sh（Go 版 twig.app）刻意不同的一点：
# 那边的 Info.plist 是 LSUIElement=true（启动完立刻退出，不占 Dock），因为
# 那个 .app 只是个"启动器"，真正的窗口是浏览器标签页。
# 这边 LSUIElement 必须是 false——这个 App 本身就是常驻的真窗口，要出现在
# Dock 里、关掉窗口后进程还活着、再点 Dock 图标能把窗口召回来。
# 实测确认过（2026-08-29）：SwiftUI 的 WindowGroup + AppKit 默认的 reopen
# 处理，这套行为不用写一行代码就有——Go 版启动器要解决的"点 Dock 没反应"
# 那个问题（坑 22），在这里天然不存在。
#
# 用法：
#   ./mac/packaging/make-app.sh          # 生成到 mac/dist/TwigMac.app
#   ./mac/packaging/make-app.sh -i       # 生成后直接装到 /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_ROOT="$ROOT/mac"
cd "$MAC_ROOT"

DIST="$MAC_ROOT/dist"
APP="$DIST/TwigMac.app"
INSTALL=false
[[ "${1:-}" == "-i" || "${1:-}" == "--install" ]] && INSTALL=true

echo "==> 编译（release，比 dev-run.sh 的 debug 版快很多、体积也小）"
mkdir -p "$DIST"
touch "$DIST/.metadata_never_index"   # 理由同 Go 那份脚本：防 Spotlight 索引出重复图标
swift build -c release

BIN=".build/release/TwigMac"
if [[ ! -x "$BIN" ]]; then
  echo "找不到编译产物：$BIN" >&2
  exit 1
fi

echo "==> 复用 Go 那份图标（同一个品牌，没必要另画一份）"
ICON_PNG="$ROOT/packaging/icon.png"
if [[ ! -f "$ICON_PNG" ]]; then
  python3 "$ROOT/packaging/make-icon.py" "$ICON_PNG"
fi
ICONSET="$DIST/TwigMac.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$ICON_PNG" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DIST/TwigMac.icns"
rm -rf "$ICONSET"

echo "==> 组装 TwigMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TwigMac"
mv "$DIST/TwigMac.icns" "$APP/Contents/Resources/TwigMac.icns"

VERSION="0.1.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>TwigMac</string>
  <key>CFBundleDisplayName</key>       <string>TwigMac</string>
  <key>CFBundleIdentifier</key>        <string>local.twig.mac</string>
  <key>CFBundleExecutable</key>        <string>TwigMac</string>
  <key>CFBundleIconFile</key>          <string>TwigMac</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <!-- ⚠️ 故意是 false，别改成 true。这是常驻窗口应用，不是启动器，见文件顶部注释。 -->
  <key>LSUIElement</key>               <false/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   （跳过签名，不影响使用）"

echo "==> 完成: $APP"
if $INSTALL; then
  rm -rf /Applications/TwigMac.app
  cp -R "$APP" /Applications/
  echo "==> 已安装到 /Applications/TwigMac.app"
  rm -rf "$DIST"
  echo "==> 已清理中间产物 dist/"
fi
