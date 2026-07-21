#!/usr/bin/env bash
# 打包 Translate.app
# 用法：
#   ./scripts/make-app.sh           # release 模式
#   ./scripts/make-app.sh debug     # debug 模式
#
# 依赖：Xcode（含 CommandLineTools，swift build 可用）

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-release}"
case "$MODE" in
    debug|release) ;;
    *) echo "用法: $0 [debug|release]"; exit 1;;
esac

APP_NAME="Translate"
DISPLAY_NAME="Translate"
BUNDLE_ID="com.translate.app"
VERSION="0.1.0"
BUILD="1"

OUT_DIR="build"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> 清理旧产物"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> swift build ($MODE)"
if [[ "$MODE" == "release" ]]; then
    CONFIG_FLAGS=(-c release)
else
    CONFIG_FLAGS=(-c debug)
fi

swift build "${CONFIG_FLAGS[@]}"

BIN_PATH=$(swift build "${CONFIG_FLAGS[@]}" --show-bin-path)
EXE="$BIN_PATH/$APP_NAME"
if [[ ! -f "$EXE" ]]; then
    echo "❌ 找不到可执行文件: $EXE"
    exit 1
fi

echo "==> 组装 .app bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp Info/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# SPM 资源包（.bundle）会编译到 .build/... 下面，要找一下
# 包括 KeyboardShortcuts 的本地化 bundle（.lproj 资源），没有它 Recorder 会触发 NSBundle.module 断言失败
# 关键：accessor 用 Bundle.main.bundleURL（.app 根）拼接查找，不查 Contents/Resources，
# 所以必须拷到 .app 根（与 Contents 同级），拷到 Contents/Resources 会 fatalError。
SPM_BUNDLES=$(find "$BIN_PATH" -name "*.bundle" 2>/dev/null || true)
if [[ -n "$SPM_BUNDLES" ]]; then
    while IFS= read -r b; do
        echo "    嵌入资源包: $(basename "$b")"
        cp -R "$b" "$APP_BUNDLE/"
    done <<< "$SPM_BUNDLES"
fi

# 签名策略：不使用 --deep（会破坏 nested SPM .bundle 的 _CodeSignature 和 Info.plist）
echo "==> ad-hoc 签名（分步）"
# 1) 清理所有 nested 现有签名
find "$APP_BUNDLE" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
# 2) 先签 nested .bundle（位于 .app 根，与 Contents 同级）
BUNDLE_LIST=$(find "$APP_BUNDLE" -maxdepth 1 -name "*.bundle" 2>/dev/null || true)
if [ -n "$BUNDLE_LIST" ]; then
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        echo "    签名 bundle: $(basename "$b")"
        codesign --force --sign - "$b"
    done <<< "$BUNDLE_LIST"
fi
# 3) 签主二进制
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# 4) 最后签 .app 顶层（不带 --deep）
codesign --force --sign - "$APP_BUNDLE"

echo
echo "✅ 完成: $APP_BUNDLE"
echo
echo "运行方式："
echo "  open $APP_BUNDLE"
echo
echo "或者拖到 /Applications"
