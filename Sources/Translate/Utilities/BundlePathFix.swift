import Foundation

/// 在应用启动时修复 CI 打包导致的 KeyboardShortcuts 资源路径 Bug。
///
/// SPM 的 `KeyboardShortcuts_KeyboardShortcuts.bundle` 被打包脚本放进了
/// `Contents/Resources/`，但运行时 KeyboardShortcuts 会在 `Contents/` 根目录下
/// 寻找它（导致 NSBundle.module 断言 / 本地化资源找不到）。
/// 这里在 `Contents/` 下创建一个指向 `Resources/` 的软链接来桥接，既不动真实
/// 文件，也不破坏各层签名的完整性。
func fixKeyboardShortcutsBundlePath() {
    let fileManager = FileManager.default

    // 1. 获取当前 App 的 Contents 目录
    let contentsURL = Bundle.main.bundleURL.appendingPathComponent("Contents")

    // 2. 正确的、符合签名规范的资源存放路径
    let srcBundle = contentsURL.appendingPathComponent("Resources/KeyboardShortcuts_KeyboardShortcuts.bundle")

    // 3. 报错日志提示它会去寻找的根目录路径
    let destBundle = contentsURL.appendingPathComponent("KeyboardShortcuts_KeyboardShortcuts.bundle")

    // 如果 Resources 下存在该 bundle，而根目录下没有
    if fileManager.fileExists(atPath: srcBundle.path) && !fileManager.fileExists(atPath: destBundle.path) {
        do {
            // 用【相对路径】创建软链接（指向 Resources/...）。
            // ⚠️ 不能用绝对路径：app 被拖到 /Applications 等其它位置后绝对路径会失效，
            // 导致 NSBundle.module 断言失败、启动即崩。
            // 相对路径以 destBundle 所在的 Contents/ 目录为基准解析。
            try fileManager.createSymbolicLink(
                atPath: destBundle.path,
                withDestinationPath: "Resources/\(srcBundle.lastPathComponent)"
            )
            print("✅ 成功创建 KeyboardShortcuts Bundle 相对软链接")
        } catch {
            print("❌ 创建软链接失败: \(error)")
        }
    }
}
