import AppKit
import SwiftUI

/// 不参与 Mission Control / 不抢焦点的悬浮窗。
/// 仿 bob 风格：磨砂背景 + 圆角 + 可切换置顶。
/// - pinned = true：浮在所有窗口之上（切应用也不被覆盖）
/// - pinned = false：切换到其他 app 时会被覆盖（窗口仍保留，可重新触发）
@MainActor
final class FloatingPanelController<Content: View> {

    private var panel: NSPanel?
    private var hosting: NSHostingController<Content>?
    /// 是否置顶（浮在所有窗口之上）。
    private(set) var pinned = false

    init() {}

    /// 显示/更新面板。
    /// - Parameters:
    ///   - viewBuilder: 构造 SwiftUI 视图
    ///   - size: 尺寸提示。width 作为固定宽度；height 作为最小高度。
    ///   - maxSize: 高度上限（超出后内容内部滚动）。默认屏幕可用高度的 70%。
    ///   - pinned: 是否置顶浮在最前。
    ///   - keepPinned: 复用现有窗口时是否保留当前置顶状态（刷新内容时不重置置顶）。
    ///   - anchor: 屏幕坐标（用于定位左上角）；nil = 当前鼠标位置
    func show(@ViewBuilder _ viewBuilder: @escaping () -> Content,
              size: NSSize = NSSize(width: 420, height: 220),
              maxSize: NSSize? = nil,
              pinned: Bool = false,
              keepPinned: Bool = false,
              anchor: NSPoint? = nil) {
        if !keepPinned {
            self.pinned = pinned
        }
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .resizable, .closable, .utilityWindow, .hudWindow],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = self.pinned
            // 即使非置顶也用 .floating 级，否则后台 app 的 normal 窗口
            // 会被前台 app 窗口盖住，翻译结果看不到。
            // 置顶（pinned）时更进一步用 .statusBar，切应用也不被覆盖。
            p.level = self.pinned ? .statusBar : .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            panel = p
        } else {
            applyPinned(self.pinned)
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

        // 外层 clip 容器：NSVisualEffectView 会重置自身 layer 的 cornerRadius，
        // 所以圆角必须由一个普通 NSView 父容器来裁剪，圆角才稳得住。
        let clip = NSView()
        clip.wantsLayer = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.clear.cgColor

        // 组装：panel.contentView = clip > effectView > host.view
        if let old = panel?.contentView {
            old.subviews.forEach { $0.removeFromSuperview() }
        }
        panel?.contentView = clip
        clip.addSubview(effectView)
        effectView.addSubview(host.view)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: clip.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: effectView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        // 自适应高度：用 SwiftUI 内容在给定宽度下测出的自然高度撑开窗口，
        // 超过上限则封顶（内容自身已带 ScrollView，超长会内部滚动）。
        let fitted = Self.fittingSize(
            for: host,
            width: size.width,
            minHeight: size.height,
            maxHeight: (maxSize?.height) ?? Self.defaultMaxHeight()
        )

        // 定位
        if let anchor = anchor {
            panel?.setFrameTopLeftPoint(anchor)
        } else {
            // 当前鼠标位置
            let mouse = NSEvent.mouseLocation
            let frame = NSRect(
                x: mouse.x - fitted.width / 2,
                y: mouse.y - fitted.height - 16,  // 鼠标上方 16px
                width: fitted.width,
                height: fitted.height
            )
            panel?.setFrame(frame, display: true)
        }
        if self.pinned {
            panel?.orderFrontRegardless()
        } else {
            // 非置顶：置于普通层级，不抢当前 app 的前台
            panel?.orderFront(nil)
        }
    }

    /// 切换置顶状态。
    func setPinned(_ on: Bool) {
        guard pinned != on else { return }
        pinned = on
        applyPinned(on)
    }

    private func applyPinned(_ on: Bool) {
        guard let p = panel else { return }
        p.isFloatingPanel = on
        p.level = on ? .statusBar : .floating
        if on {
            p.orderFrontRegardless()
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    func isVisible() -> Bool {
        panel?.isVisible ?? false
    }

    private static func defaultMaxHeight() -> CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.7
    }

    /// 在固定宽度下测量 SwiftUI 内容的自然高度。
    private static func fittingSize(for host: NSHostingController<Content>,
                                    width: CGFloat,
                                    minHeight: CGFloat,
                                    maxHeight: CGFloat) -> NSSize {
        // 先给一个目标宽度，让 hostingView 算出 fittingSize
        host.view.setFrameSize(NSSize(width: width, height: 1000))
        host.view.layoutSubtreeIfNeeded()
        var fitted = host.view.fittingSize
        // fittingSize 的宽度可能略大于目标（NSHostingController 对宽度有时不收缩），
        // 以传入宽度为准。
        fitted.width = width
        fitted.height = min(max(fitted.height, minHeight), maxHeight)
        return fitted
    }
}
