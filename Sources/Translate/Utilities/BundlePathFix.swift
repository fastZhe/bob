import Foundation

/// 在应用启动时修复 CI 打包导致的 KeyboardShortcuts 资源路径 Bug。
///
/// 经运行时诊断确认：KeyboardShortcuts 的 `Bundle.module`（由 SPM
/// `resource_bundle_accessor` 生成）实际在 **`Bundle.main.bundleURL`**（即
/// `.app` 根目录，例如 `/Applications/Translate.app/`）下查找
/// `KeyboardShortcuts_KeyboardShortcuts.bundle`，而不是 `Contents/` 或
/// `Contents/Resources/`。
///
/// 但打包规范要求资源放在 `Contents/Resources/`。所以在 `.app` 根目录下建一个
/// 指向 `Contents/Resources/<bundle>` 的【相对】软链接来桥接：
/// - 相对路径保证 app 被拖到任意位置（如 /Applications）链接都不会断；
/// - 软链接不动真实文件，不破坏签名封印。
///
/// accessor 拼出的候选路径 `bundleURL + bundleName` 会命中这个 symlink，
/// 解析到真实的 `Contents/Resources/<bundle>`，从而 `Bundle(path:)` 成功。
func fixKeyboardShortcutsBundlePath() {
    let fileManager = FileManager.default
    let bundleName = "KeyboardShortcuts_KeyboardShortcuts.bundle"

    // Bundle.main.bundleURL = .app 根目录（如 /Applications/Translate.app/）
    let appURL = Bundle.main.bundleURL
    // 真实资源路径：.app/Contents/Resources/<bundle>
    let realPath = appURL.appendingPathComponent("Contents/Resources/\(bundleName)")

    guard fileManager.fileExists(atPath: realPath.path) else {
        // Resources 下都没有 bundle，没法兜底
        return
    }

    // 在 .app 根目录下建相对 symlink -> Contents/Resources/<bundle>
    let linkURL = appURL.appendingPathComponent(bundleName)
    if fileManager.fileExists(atPath: linkURL.path) { return }
    do {
        try fileManager.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: "Contents/Resources/\(bundleName)"
        )
        print("✅ 创建相对软链接: \(bundleName) @ .app 根 -> Contents/Resources/\(bundleName)")
    } catch {
        print("❌ 创建软链接失败 (\(linkURL.path)): \(error)")
    }
}
