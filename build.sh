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

# 用 macOS 26 SDK 而不是默认(最新)的那个。
#
# 更新的 SDK 里 SwiftUI 把 @State 声明成了宏,展开需要 SwiftUIMacros 插件,
# 而该插件只随 Xcode.app 分发,Command Line Tools 里没有 —— 于是任何用到 @State
# 的文件都编不过。26 的 SwiftUI 还没这么做,所以 CLT 环境仍然能独立构建。
#
# 挑现有 SDK 里能用的那个;都没有就退回默认,让 swiftc 自己报错。
SDK=""
for candidate in MacOSX26.sdk MacOSX26.5.sdk; do
  if [ -d "/Library/Developer/CommandLineTools/SDKs/$candidate" ]; then
    SDK="/Library/Developer/CommandLineTools/SDKs/$candidate"
    break
  fi
done

if [ -n "$SDK" ]; then
  echo "▸ 使用 SDK:$(basename "$SDK")"
  SDK_ARGS=(-sdk "$SDK")
else
  echo "  ⚠︎ 未找到 macOS 26 SDK,改用默认 SDK"
  echo "     若报 SwiftUIMacros 缺失,需要安装 Xcode 或补上该 SDK"
  SDK_ARGS=()
fi

echo "▸ 编译 Swift…"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  "${SDK_ARGS[@]}" \
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
