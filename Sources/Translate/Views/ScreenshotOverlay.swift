import AppKit
import SwiftUI

/// 截图选区流程控制
@MainActor
final class ScreenshotOverlayController {

    private var window: NSWindow?
    private var selectionView: ScreenshotSelectionView?
    /// 全局事件监听：兜底捕获 mouseUp / ESC，不依赖 view 是否 first responder。
    /// 后台 LSUIElement app 的 borderless 窗口有时 mouseUp 会丢，导致选完松手没反应。
    private var monitor: Any?

    /// 启动截图选区流程。
    /// 流程：截全屏 → 全屏窗口显示 → 用户框选 → 裁剪返回。
    /// - onResult: 用户框选完成（image）或取消（nil）。
    /// - onError: 截全屏阶段失败（通常是屏幕录制权限未授权）。
    func start(screenshot: ScreenshotService,
               onResult: @escaping (NSImage?) -> Void,
               onError: @escaping (Error) -> Void) {
        Task { @MainActor in
            do {
                let full = try await screenshot.captureFullScreen()
                self.presentOverlay(fullImage: full, onResult: onResult)
            } catch {
                Log.screen.error("capture failed: \(error.localizedDescription, privacy: .public)")
                onError(error)
            }
        }
    }

    private func presentOverlay(fullImage: NSImage, onResult: @escaping (NSImage?) -> Void) {
        guard let screen = NSScreen.main else { onResult(nil); return }
        // 用 visibleFrame（排除菜单栏/Dock），避免覆盖在菜单栏上导致看起来画面错位。
        let frame = screen.visibleFrame

        let view = ScreenshotSelectionView(frame: frame, image: fullImage)
        view.onSelect = { [weak self] rectInImage in
            self?.teardown()
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.selectionView = nil
            let cropped = Self.crop(image: fullImage, rectInImage: rectInImage)
            onResult(cropped)
        }
        view.onCancel = { [weak self] in
            self?.teardown()
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.selectionView = nil
            onResult(nil)
        }
        selectionView = view

        // 自定义子类：borderless 窗口默认不能成为 key，ESC/键盘事件收不到。
        let w = KeyableBorderlessWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = false
        w.contentView = view
        // 必须激活 app，否则后台菜单栏 app 的窗口收不到键盘事件（ESC 取消不了）。
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // 显式把 view 设为 first responder，确保 mouseUp / keyDown 能派发到它。
        w.makeFirstResponder(view)
        view.hostWindow = w
        window = w

        // 全局事件兜底：后台 app 的 borderless 窗口有时 mouseUp/ESC 事件会丢，
        // 用 local monitor 兜底，确保选完松手能确认、ESC 能取消。
        installMonitor()
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
            guard let self = self, self.window != nil else { return event }
            if event.type == .leftMouseUp {
                self.selectionView?.finishSelectionIfDragging()
            } else if event.type == .keyDown, event.keyCode == 53 {  // ESC
                self.selectionView?.cancel()
            }
            return event
        }
    }

    private func teardown() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// rectInImage 用 NSImage.size 坐标（原点在左下）
    private static func crop(image: NSImage, rectInImage: NSRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // image.size 是 points；cgImage 用 pixels
        let scaleX = CGFloat(cg.width)  / image.size.width
        let scaleY = CGFloat(cg.height) / image.size.height
        let pixelRect = NSRect(
            x: rectInImage.origin.x * scaleX,
            y: rectInImage.origin.y * scaleY,
            width:  rectInImage.size.width  * scaleX,
            height: rectInImage.size.height * scaleY
        )
        guard let cropped = cg.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: rectInImage.size)
    }
}

// MARK: - NSView 实现

/// borderless 窗口默认 canBecomeKeyWindow=false，收不到键盘事件。
/// 子类化让 ESC 取消能生效。
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class ScreenshotSelectionView: NSView {

    private let image: NSImage
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    fileprivate weak var hostWindow: NSWindow?

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 画全屏截图
        image.draw(in: bounds,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0)

        // 2. 半透明遮罩
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)

        // 3. 选区
        if let s = startPoint, let c = currentPoint {
            let rect = normalizedRect(s, c)
            if rect.width > 1, rect.height > 1 {
                // 挖空选区：先把这一区域恢复原图
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    // 屏幕坐标 → 原图坐标（points）
                    let scaleX = image.size.width  / bounds.width
                    let scaleY = image.size.height / bounds.height
                    let imgRect = NSRect(
                        x: rect.origin.x * scaleX,
                        y: rect.origin.y * scaleY,
                        width: rect.width * scaleX,
                        height: rect.height * scaleY
                    )
                    // 用 image 画到 rect 上（src = imgRect, dst = rect）
                    image.draw(in: rect,
                               from: imgRect,
                               operation: .sourceOver,
                               fraction: 1.0)
                    _ = cg
                }
                // 选区边框
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(rect)
                // 选区角点
                let dotR: CGFloat = 4
                ctx.setFillColor(NSColor.white.cgColor)
                for p in [NSPoint(x: rect.minX, y: rect.minY),
                          NSPoint(x: rect.maxX, y: rect.minY),
                          NSPoint(x: rect.minX, y: rect.maxY),
                          NSPoint(x: rect.maxX, y: rect.maxY)] {
                    ctx.fillEllipse(in: NSRect(x: p.x - dotR, y: p.y - dotR, width: dotR*2, height: dotR*2))
                }
                // 尺寸标签
                drawSizeBadge(rect: rect)
            }
        }

        // 4. 顶部提示
        drawHintBanner()
    }

    private func drawHintBanner() {
        let text = "拖动框选翻译区域 · ESC 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let padding: CGFloat = 10
        let bgRect = NSRect(
            x: (bounds.width - size.width) / 2 - padding,
            y: bounds.height - 50 - size.height / 2,
            width: size.width + padding * 2,
            height: size.height + 10
        )
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        str.draw(at: NSPoint(x: bgRect.origin.x + padding, y: bgRect.origin.y + 5))
    }

    private func drawSizeBadge(rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let bgRect = NSRect(
            x: rect.maxX - size.width - 14,
            y: rect.maxY + 4,
            width: size.width + 12,
            height: size.height + 6
        )
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        path.fill()
        str.draw(at: NSPoint(x: bgRect.origin.x + 6, y: bgRect.origin.y + 3))
    }

    // MARK: - Events

    /// 完成选区（mouseUp 或全局 monitor 兜底调用）。
    /// 用 guard 防止重复触发（mouseUp 和 monitor 可能都调到）。
    fileprivate func finishSelectionIfDragging() {
        guard let s = startPoint, let c = currentPoint else { return }
        // 清空起点，防止 monitor 与 mouseUp 重复触发
        startPoint = nil
        currentPoint = nil
        let rect = normalizedRect(s, c)
        if rect.width >= 5, rect.height >= 5 {
            // 转换成 NSImage 坐标（points，原点在左下）
            let imgRect = NSRect(
                x: rect.origin.x,
                y: bounds.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            onSelect?(imgRect)
        } else {
            onCancel?()
        }
    }

    /// 取消选区（ESC 或全局 monitor 兜底调用）。
    fileprivate func cancel() {
        startPoint = nil
        currentPoint = nil
        onCancel?()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentPoint = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        finishSelectionIfDragging()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC
            onCancel?()
        }
    }

    private func normalizedRect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
