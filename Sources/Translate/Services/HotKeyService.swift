import Foundation
import AppKit
import KeyboardShortcuts

/// 全局快捷键的命名（让设置面板能引用）
extension KeyboardShortcuts.Name {
    static let translateSelection  = Self("translateSelection")
    static let translateScreenshot  = Self("translateScreenshot")
    static let translateClipboard   = Self("translateClipboard")
}

/// 注册 / 监听全局快捷键
@MainActor
final class HotKeyService {

    var onSelection: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onClipboard:  (() -> Void)?

    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true

        // 默认快捷键（用户在偏好设置里可改）
        if KeyboardShortcuts.getShortcut(for: .translateSelection) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .option, .control]),
                for: .translateSelection
            )
        }
        if KeyboardShortcuts.getShortcut(for: .translateScreenshot) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .option, .shift]),
                for: .translateScreenshot
            )
        }
        if KeyboardShortcuts.getShortcut(for: .translateClipboard) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .option, .control]),
                for: .translateClipboard
            )
        }

        KeyboardShortcuts.onKeyDown(for: .translateSelection) { [weak self] in
            self?.onSelection?()
        }
        KeyboardShortcuts.onKeyDown(for: .translateScreenshot) { [weak self] in
            self?.onScreenshot?()
        }
        KeyboardShortcuts.onKeyDown(for: .translateClipboard) { [weak self] in
            self?.onClipboard?()
        }

        Log.hotkey.info("Hotkeys installed (defaults: ⌃⌥⌘D / ⌘⌥⇧S / ⌃⌥⌘V)")
    }
}
