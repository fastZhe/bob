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
            // 创建一个软链接（快捷方式），不需要复制真实文件
            // 这样既不破坏 Contents/ 目录的签名完整性，又能让代码顺着软链接找到 Resources 里的内容
            try fileManager.createSymbolicLink(at: destBundle, withDestinationURL: srcBundle)
            print("✅ 成功创建 KeyboardShortcuts Bundle 软链接，绕过签名与路径限制")
        } catch {
            print("❌ 创建软链接失败: \(error)")
        }
    }
}
