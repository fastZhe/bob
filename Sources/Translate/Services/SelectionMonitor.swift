import AppKit

/// 全局监听鼠标抬起，自动用模拟 Cmd+C 抓取当前选中文本。
/// 需要**辅助功能权限**（系统设置 → 隐私与安全性 → 辅助功能）。
@MainActor
final class SelectionMonitor {

    private var monitor: Any?
    private var onCapture: ((String) -> Void)?

    /// 启动监听。回调在主线程触发。
    func start(onCapture: @escaping (String) -> Void) {
        stop()
        self.onCapture = onCapture

        // 监听 mouseUp：用户松手时尝试读取当前 selection
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.tryCapture()
            }
        }

        if monitor == nil {
            Log.sel.error("addGlobalMonitorForEvents 返回 nil — 大概率没开辅助功能权限")
        } else {
            Log.sel.info("Selection monitor started")
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        onCapture = nil
    }

    // MARK: - Private

    private func tryCapture() async {
        // 50ms 延迟，让系统处理默认 click
        try? await Task.sleep(nanoseconds: 50_000_000)
        // macOS 上 NSPasteboard.general 不会因模拟 Cmd+C 写到自己的 pasteboard 吗？不会，
        // 系统级 Cmd+C 写到通用 pasteboard 会被我们的模拟触发。
        let pb = NSPasteboard.general
        let old = pb.changeCount

        simulateCopy()

        // 等剪贴板更新（最多 200ms）
        let deadline = Date().addingTimeInterval(0.2)
        while pb.changeCount == old, Date() < deadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }

        guard pb.changeCount != old, let text = pb.string(forType: .string), !text.isEmpty else {
            return
        }
        onCapture?(text)
    }

    private func simulateCopy() {
        let src = CGEventSource(stateID: .hidSystemState)
        // kVK_ANSI_C = 0x08
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
    }
}
