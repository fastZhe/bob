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
# 包括 KeyboardShortcuts 的本地化 bundle（.lproj 资源），没有它 Recorder 会触发
# NSBundle.module 断言失败（启动即崩 EXC_BREAKPOINT/SIGTRAP）。
#
# ⚠️ 关键：KeyboardShortcuts 的 Bundle.module（SPM resource_bundle_accessor 生成）
# 经过反汇编 + 运行时诊断确认，它的查找逻辑是：
#   候选1: Bundle.main.bundleURL + "<bundle>"  ← Bundle.main.bundleURL = .app 根目录!
#   候选2: 硬编码的 .build/.../build 路径绝对路径（CI 机器才存在）
#   两者都 nil → fatalError("could not load resource bundle...")
# 所以 bundle 必须出现在【.app 根目录】下，而不是 Contents/ 或 Contents/Resources/。
#
# 但 .app 规范要求资源在 Contents/Resources/。折中方案：
#   - 真实 bundle 放 Contents/Resources/（符合规范）
#   - 在 .app 根目录建一个指向 Contents/Resources/<bundle> 的【相对】symlink
#     （相对路径保证 app 被拖到 /Applications 等任意位置都不会断）
# ad-hoc 签名下，.app 根多出 symlink 会让 codesign --verify 报
# "unsealed contents present in the bundle root"，但不影响运行（已 open 验证）。
SPM_BUNDLES=$(find "$BIN_PATH" -name "*.bundle" 2>/dev/null || true)
if [[ -n "$SPM_BUNDLES" ]]; then
    while IFS= read -r b; do
        local_name=$(basename "$b")
        echo "    嵌入资源包: $local_name"
        # 1) 真实 bundle 放 Contents/Resources/
        cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
        # 2) .app 根目录建相对 symlink -> Contents/Resources/<bundle>
        #    （accessor 候选1会命中这个 symlink，解析到 Contents/Resources 里的真实 bundle）
        link_path="$APP_BUNDLE/$local_name"
        if [[ ! -e "$link_path" ]]; then
            ln -s "Contents/Resources/$local_name" "$link_path"
            echo "    建相对 symlink: ${link_path#$APP_BUNDLE/} -> Contents/Resources/$local_name"
        fi
    done <<< "$SPM_BUNDLES"
fi

# 签名策略：ad-hoc，从内到外
echo "==> ad-hoc 签名（分步）"
# 1) 清理所有 nested 现有签名（包括 SPM resource bundle 自带的）
find "$APP_BUNDLE" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
#
# ⚠️ 注意：SPM 的 resource bundle（KeyboardShortcuts_KeyboardShortcuts.bundle）
# 是【扁平结构】——Info.plist 直接在 .bundle/ 根下，没有 Contents/ 子目录。
# 如果对它单独跑 `codesign --force --sign -`，codesign 会按「macOS bundle」
# 规则去期待 Contents/Info.plist，把扁平结构签坏 → 运行时 Bundle(path:) 加载
# 失败返回 nil → KeyboardShortcuts 的 NSBundle.module 断言 → 启动即崩
# (EXC_BREAKPOINT/SIGTRAP)。
#
# 因此这些扁平 resource bundle 不能单独签名，当作普通资源目录，随主 app 顶层
# 签名一起封印即可（顶层 codesign 会递归 seal 所有嵌套资源）。
#
# 2) 签主二进制
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# 3) 签 .app 顶层（会封印 Resources/ 下所有资源，含扁平 .bundle）
codesign --force --sign - "$APP_BUNDLE"

echo
echo "✅ 完成: $APP_BUNDLE"
echo
echo "运行方式："
echo "  open $APP_BUNDLE"
echo
echo "或者拖到 /Applications"
