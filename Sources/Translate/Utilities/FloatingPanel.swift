import AppKit
import SwiftUI

/// 不参与 Mission Control / 浮动在所有窗口之上 / 不抢焦点的悬浮窗。
/// 仿 bob 风格：磨砂背景 + 圆角 + 自动 ESC 关闭。
@MainActor
final class FloatingPanelController<Content: View> {

    private var panel: NSPanel?
    private var hosting: NSHostingController<Content>?
    private var dismissObserver: Any?

    init() {}

    /// 显示/更新面板。
    /// - Parameters:
    ///   - viewBuilder: 构造 SwiftUI 视图
    ///   - size: 初始尺寸
    ///   - anchor: 屏幕坐标（用于定位左上角）；nil = 当前鼠标位置
    func show(@ViewBuilder _ viewBuilder: @escaping () -> Content,
              size: NSSize = NSSize(width: 420, height: 220),
              anchor: NSPoint? = nil) {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .resizable, .closable, .utilityWindow, .hudWindow],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            panel = p
        }

        let host = NSHostingController(rootView: viewBuilder())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = 12
        host.view.layer?.masksToBounds = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting = host

        // 用 NSVisualEffectView 做磨砂（SwiftUI 的 .background(.regularMaterial) 在 hudWindow 上有时不显示）
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        // 组装
        if let old = panel?.contentView {
            old.subviews.forEach { $0.removeFromSuperview() }
        }
        panel?.contentView = effectView
        effectView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: effectView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        // 定位
        if let anchor = anchor {
            panel?.setFrameTopLeftPoint(anchor)
        } else {
            // 当前鼠标位置
            let mouse = NSEvent.mouseLocation
            let frame = NSRect(
                x: mouse.x - size.width / 2,
                y: mouse.y - size.height - 16,  // 鼠标上方 16px
                width: size.width,
                height: size.height
            )
            panel?.setFrame(frame, display: true)
        }
        panel?.orderFrontRegardless()

        installDismissHandlers()
    }

    func close() {
        panel?.orderOut(nil)
        removeDismissHandlers()
    }

    func isVisible() -> Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Dismiss

    private func installDismissHandlers() {
        removeDismissHandlers()
        guard let target = panel else { return }
        dismissObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: target,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.close()
            }
        }
    }

    private func removeDismissHandlers() {
        if let o = dismissObserver { NotificationCenter.default.removeObserver(o) }
        dismissObserver = nil
    }
}
