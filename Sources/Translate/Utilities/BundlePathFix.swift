import Foundation

/// 在应用启动时修复 CI 打包导致的 KeyboardShortcuts 资源路径 Bug。
///
/// SPM 的 `KeyboardShortcuts_KeyboardShortcuts.bundle` 被打包脚本放进了
/// `Contents/Resources/`，但 KeyboardShortcuts 的 `Bundle.module`（由 SPM
/// `resource_bundle_accessor` 生成）查找基准目录不确定：可能是
/// `Bundle.main.bundleURL`（= `Contents/`），也可能是可执行文件所在目录
/// `Contents/MacOS/`，取决于 Swift 工具链版本。基准目录下没有该 bundle 就会
/// 触发 `assertionFailure` → 启动即崩（EXC_BREAKPOINT / SIGTRAP）。
///
/// 这里在 `Contents/` 和 `Contents/MacOS/` 两个目录下都创建指向 `Resources/`
/// 的【相对】软链接来桥接：
/// - 相对路径保证 app 被拖到任意位置（如 /Applications）链接都不会断；
/// - 软链接不动真实文件，不破坏各层签名的完整性。
func fixKeyboardShortcutsBundlePath() {
    let fileManager = FileManager.default
    let bundleName = "KeyboardShortcuts_KeyboardShortcuts.bundle"

    // 1. 获取当前 App 的 Contents 目录
    let contentsURL = Bundle.main.bundleURL.appendingPathComponent("Contents")

    // 2. 真实资源路径：Contents/Resources/<bundle>
    let srcBundle = contentsURL.appendingPathComponent("Resources/\(bundleName)")

    guard fileManager.fileExists(atPath: srcBundle.path) else {
        // Resources 下都没有 bundle，没法兜底
        return
    }

    // 3. 两个候选基准目录，分别建相对 symlink
    //    - Contents/<bundle>      -> Resources/<bundle>
    //    - Contents/MacOS/<bundle> -> ../Resources/<bundle>
    let candidates: [(dir: URL, dest: String)] = [
        (contentsURL, "Resources/\(bundleName)"),
        (contentsURL.appendingPathComponent("MacOS"), "../Resources/\(bundleName)")
    ]

    for (dir, dest) in candidates {
        let linkURL = dir.appendingPathComponent(bundleName)
        if fileManager.fileExists(atPath: linkURL.path) { continue }
        do {
            try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: dest)
            print("✅ 创建相对软链接: \(linkURL.lastPathComponent) @ \(dir.lastPathComponent) -> \(dest)")
        } catch {
            print("❌ 创建软链接失败 (\(linkURL.path)): \(error)")
        }
    }
}
