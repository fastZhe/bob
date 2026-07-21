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
# 新版 Swift 工具链生成的 resource_bundle_accessor 查 Bundle.main.resourceURL
# （即 Contents/Resources），bundle 放这里即可命中。
#
# ⚠️ 但 KeyboardShortcuts 的 resource_bundle_accessor 实际会在 Bundle.main.bundleURL
# （即 Contents/）根目录下寻找 KeyboardShortcuts_KeyboardShortcuts.bundle，
# 而不是 Contents/Resources。所以光放进 Resources 还不够，必须在 Contents/ 下
# 建一个指向 Resources/ 的【相对】symlink（绝对路径 symlink 在 app 被移动到
# /Applications 等其它位置后会失效，导致 NSBundle.module 断言启动即崩）。
SPM_BUNDLES=$(find "$BIN_PATH" -name "*.bundle" 2>/dev/null || true)
if [[ -n "$SPM_BUNDLES" ]]; then
    while IFS= read -r b; do
        echo "    嵌入资源包: $(basename "$b")"
        cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
        # 在 Contents/ 下建相对 symlink 指向 Resources/<bundle>
        # 这样无论 app 被拖到哪个目录，链接都不会断
        local_name=$(basename "$b")
        # SPM resource_bundle_accessor 的查找基准目录不确定（可能是
        # Bundle.main.bundleURL=Contents/，也可能是可执行文件所在 Contents/MacOS/，
        # 取决于 Swift 工具链版本）。在两个目录下都建相对 symlink 覆盖两种情况。
        # 相对路径以各自所在目录为基准解析，app 被拖到任意位置都不会断。
        for base_dir in "$APP_BUNDLE/Contents" "$APP_BUNDLE/Contents/MacOS"; do
            link_path="$base_dir/$local_name"
            if [[ ! -e "$link_path" ]]; then
                if [[ "$base_dir" == *"/MacOS" ]]; then
                    ln -s "../Resources/$local_name" "$link_path"
                else
                    ln -s "Resources/$local_name" "$link_path"
                fi
                echo "    建相对 symlink: ${link_path#$APP_BUNDLE/} -> Resources/$local_name"
            fi
        done
    done <<< "$SPM_BUNDLES"
fi

# 签名策略：先签嵌套 .bundle，再签主二进制，最后签 .app 顶层
echo "==> ad-hoc 签名（分步）"
# 1) 清理所有 nested 现有签名
find "$APP_BUNDLE" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
# 2) 先签 .bundle（位于 Contents/Resources）
BUNDLE_LIST=$(find "$APP_BUNDLE/Contents/Resources" -name "*.bundle" 2>/dev/null || true)
if [ -n "$BUNDLE_LIST" ]; then
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        echo "    签名 bundle: $(basename "$b")"
        codesign --force --sign - "$b"
    done <<< "$BUNDLE_LIST"
fi
# 3) 签主二进制
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# 4) 签 .app 顶层
codesign --force --sign - "$APP_BUNDLE"

echo
echo "✅ 完成: $APP_BUNDLE"
echo
echo "运行方式："
echo "  open $APP_BUNDLE"
echo
echo "或者拖到 /Applications"
