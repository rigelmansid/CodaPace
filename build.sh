#!/bin/bash
# 构建 CodaPace.app
#
# 只产出 arm64(Apple Silicon)。Intel Mac 无法运行。
#
# Core 和 App 两个目录一起编成同一个模块,所以 App 层不需要 import。
# Package.swift 另外把 Sources/Core 单独暴露给测试(swift run CoreTests),
# 两边共用同一份源码。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/CodaPace.app"

echo "▸ 清理旧的构建产物…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 写入 Info.plist…"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# 图标由 Scripts/make-icon.swift 生成,不在每次构建时重跑(渲染 10 个尺寸要几秒)
if [ -f "$DIR/Resources/AppIcon.icns" ]; then
  echo "▸ 拷贝应用图标…"
  cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  ⚠︎ 未找到 Resources/AppIcon.icns,将使用系统默认图标"
  echo "     生成方式：swift Scripts/make-icon.swift"
fi

echo "▸ 收集源文件…"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$DIR/Sources/Core" "$DIR/Sources/App" -name '*.swift' -print0)
echo "  ${#SOURCES[@]} 个文件"

echo "▸ 编译 Swift…"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework Charts \
  -lsqlite3 \
  -o "$APP/Contents/MacOS/CodaPace" \
  "${SOURCES[@]}"

echo "▸ 签名（ad-hoc,本机使用足够）…"
codesign --force --sign - "$APP"

echo ""
echo "✅ 构建完成"
echo "   $APP"
echo ""
echo "   运行：open \"$APP\""
