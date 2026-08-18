#!/bin/bash
# 把 twig 打包成 macOS 的 twig.app —— 双击就能用，不必回终端敲命令。
#
# 这个 .app 只是个启动器：双击后它把 twig 服务放到后台跑、打开浏览器，
# 自己立刻退出。所以它不常驻 Dock，也不会因为关掉 App 而杀掉服务。
# 如果已经有一个 twig 在跑，再双击只会把浏览器带到那个实例上，不会起第二个。
#
# 用法：
#   ./packaging/make-app.sh                # 生成到 dist/twig.app
#   ./packaging/make-app.sh -i             # 生成后直接装到 /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/twig.app"
INSTALL=false
[[ "${1:-}" == "-i" || "${1:-}" == "--install" ]] && INSTALL=true

echo "==> 编译二进制"
mkdir -p "$DIST"
go build -o "$DIST/twig-bin" .

echo "==> 生成图标"
ICON_PNG="$ROOT/packaging/icon.png"
if [[ ! -f "$ICON_PNG" ]]; then
  # 图标是脚本画出来的，仓库里带了一份成品；万一丢了就重新画（要跑几十秒）
  python3 "$ROOT/packaging/make-icon.py" "$ICON_PNG"
fi

ICONSET="$DIST/twig.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# iconutil 要求这一整套尺寸，名字是固定格式
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$ICON_PNG" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DIST/twig.icns"
rm -rf "$ICONSET"

echo "==> 组装 twig.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$DIST/twig-bin" "$APP/Contents/MacOS/twig"
mv "$DIST/twig.icns" "$APP/Contents/Resources/twig.icns"

# 启动器：把服务丢到后台，自己退出
cat > "$APP/Contents/MacOS/twig-launcher" <<'LAUNCHER'
#!/bin/sh
# twig.app 的入口。真正的服务是同目录下的 twig 二进制。
DIR=$(cd "$(dirname "$0")" && pwd)
LOG="$HOME/.twig/twig.log"
mkdir -p "$HOME/.twig"

# 日志别无限长：超过 1MB 就从头来
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
  : > "$LOG"
fi

# 双击 App 时当前目录是 /，不是仓库，twig 会自动回到上次打开的那个仓库。
# 已经有实例在跑的话，它会把浏览器带过去然后自行退出。
nohup "$DIR/twig" >> "$LOG" 2>&1 &
LAUNCHER
chmod +x "$APP/Contents/MacOS/twig-launcher"

VERSION="0.1.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>twig</string>
  <key>CFBundleDisplayName</key>       <string>twig</string>
  <key>CFBundleIdentifier</key>        <string>local.twig.app</string>
  <key>CFBundleExecutable</key>        <string>twig-launcher</string>
  <key>CFBundleIconFile</key>          <string>twig</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <!-- 启动完就退出，不需要在 Dock 里占位 -->
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# 临时签名：本地自己 build 的不需要证书，签一下能少一些系统层面的啰嗦
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   （跳过签名，不影响使用）"

echo "==> 完成: $APP"
if $INSTALL; then
  rm -rf /Applications/twig.app
  cp -R "$APP" /Applications/
  echo "==> 已安装到 /Applications/twig.app"
fi
