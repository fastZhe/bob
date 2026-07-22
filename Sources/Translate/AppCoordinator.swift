import AppKit
import SwiftUI
import ApplicationServices
import ScreenCaptureKit

/// 全局 app 协调器。
/// - 持有配置 & 服务
/// - 注册全局快捷键回调
/// - 接受"翻译选中文本 / 截图 / 剪贴板"三种 action
/// - 显示 / 关闭悬浮结果窗
@MainActor
final class AppCoordinator: ObservableObject {

    static let shared = AppCoordinator()

    // MARK: - 状态

    @Published var settings = SettingsStore()

    @Published var lastResult: TranslationResult?
    @Published var isWorking = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// 结果悬浮窗是否置顶
    @Published var resultPanelPinned = false

    /// 三态：nil = 未检测，true = 已授权，false = 已知未授权
    @Published var hasAccessibilityPermission: Bool? = nil
    /// 三态：nil = 未检测，true = 已授权，false = 已知未授权
    @Published var hasScreenCapturePermission: Bool? = nil

    // MARK: - 服务

    let translate  = TranslateService()
    let hotKey     = HotKeyService()
    let selection  = SelectionMonitor()
    let screenshot = ScreenshotService()
    let ocr        = OCRService()

    private var resultPanel: FloatingPanelController<AnyView>?
    private var workingTask: Task<Void, Never>?
    private var lastSource: TranslationRequest.Source = .selection
    /// 截图选区控制器：必须持有，否则 onResult 闭包里的 weak self 在选区完成前
    /// 就随 controller 释放，导致 overlay 窗口 orderOut 不执行、画面卡在灰色选区态。
    private var screenshotOverlay: ScreenshotOverlayController?

    private init() {
        // 修复 CI 打包后 KeyboardShortcuts bundle 路径不匹配的问题
        // （bundle 在 Contents/Resources/，运行时却去 Contents/ 根目录找）
        fixKeyboardShortcutsBundlePath()

        hotKey.onSelection = { [weak self] in self?.translateSelectionNow() }
        hotKey.onScreenshot = { [weak self] in self?.translateScreenshotNow() }
        hotKey.onClipboard  = { [weak self] in self?.translateClipboardNow() }
        hotKey.install()
        // 注意：不能调 AXIsProcessTrustedWithOptions —— ad-hoc 签名下必崩 SIGSEGV
        // 也不要自动检测屏幕录制权限 —— 让用户通过功能失败来发现
    }

    /// 在 SwiftUI scene 已构建后调用一次（保留供将来扩展，目前不做事）
    func bootstrap() {
        // 留空：自动权限检测在 ad-hoc 签名下不安全
    }

    // MARK: - 三种入口 action

    /// 翻译当前选中文本（直接读剪贴板，避免再走 SelectionMonitor 时序问题）
    func translateSelectionNow() {
        guard ensurePermissionsForSelection() else { return }
        // 先抓取剪贴板内容（选中文本就靠 cmd+c 读出来）
        let pb = NSPasteboard.general
        let old = pb.changeCount
        simulateCopy()
        // 重试读取：剪贴板更新可能延迟
        tryReadSelection(pb: pb, oldChangeCount: old, retriesLeft: 5, delayMs: 100)
    }

    private func tryReadSelection(pb: NSPasteboard, oldChangeCount: Int, retriesLeft: Int, delayMs: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) { [weak self] in
            guard let self = self else { return }
            if pb.changeCount != oldChangeCount, let text = pb.string(forType: .string), !text.isEmpty {
                self.runTranslate(text: text, imageData: nil, source: .selection)
                return
            }
            if retriesLeft > 0 {
                // 模拟一次没生效，再模拟一次（用户可能多按了快捷键/剪贴板延迟）
                self.simulateCopy()
                self.tryReadSelection(pb: pb, oldChangeCount: oldChangeCount, retriesLeft: retriesLeft - 1, delayMs: delayMs)
            } else {
                // fallback：剪贴板里可能有内容（用户之前 ⌘C 过）
                if let text = pb.string(forType: .string), !text.isEmpty {
                    self.runTranslate(text: text, imageData: nil, source: .clipboard)
                    return
                }
                // 真没东西，给清晰提示
                let hint: String
                if self.hasAccessibilityPermission == false {
                    hint = "请到 系统设置 → 隐私与安全性 → 辅助功能 勾选「Translate」。"
                } else {
                    hint = "1) 确保已选中要翻译的文字\n2) 试一下手动按 ⌘C 后再按本快捷键\n3) 部分 app（如 Electron / 浏览器 / 远程桌面）不响应模拟 ⌘C\n4) 可改用 ⌃⌥⌘V（剪贴板翻译）：先 ⌘C 再按本快捷键"
                }
                self.showError("未检测到选中文本。\n\n\(hint)")
            }
        }
    }

    /// 截图翻译
    func translateScreenshotNow() {
        guard ensurePermissionsForScreenshot() else { return }
        // 不提前显示结果面板：先全屏截图 + 弹选区框，
        // 截图/选区失败时不要留一个空面板。
        statusMessage = "请框选截图区域…"
        isWorking = true

        let overlay = ScreenshotOverlayController()
        screenshotOverlay = overlay
        overlay.start(
            screenshot: screenshot,
            onResult: { [weak self] image in
                guard let self = self else { return }
                // 选区流程结束，释放 overlay（其内部已 orderOut 窗口）
                self.screenshotOverlay = nil
                guard let image = image else {
                    // 用户取消选区
                    self.isWorking = false
                    self.statusMessage = nil
                    return
                }
                self.processScreenshot(image)
            },
            onError: { [weak self] error in
                guard let self = self else { return }
                self.screenshotOverlay = nil
                self.isWorking = false
                self.statusMessage = nil
                // 截屏失败绝大多数是屏幕录制权限问题，主动引导授权
                if let captureError = error as? ScreenshotService.CaptureError,
                   case .permissionDenied = captureError {
                    self.hasScreenCapturePermission = false
                    self.showError("需要「屏幕录制」权限才能截图翻译。\n请到 系统设置 → 隐私与安全性 → 屏幕录制 勾选「Translate」，授权后重新触发本功能。")
                    self.requestScreenCapturePermission()
                } else {
                    self.showError("截图失败：\(error.localizedDescription)")
                }
            }
        )
    }

    /// 翻译剪贴板内容
    func translateClipboardNow() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showError("剪贴板为空，请先复制要翻译的文本。")
            return
        }
        runTranslate(text: text, imageData: nil, source: .clipboard)
    }

    // MARK: - 设置

    private var settingsWindow: NSWindow?

    func openPreferences() {
        // 不依赖 SwiftUI Settings scene（MenuBarExtra .menu 下 sendAction 不可靠）
        // 自己管理一个 NSWindow
        if let win = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = PreferencesView(settings: settings)
            .environmentObject(self)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Translate 设置"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 600, height: 480))
        win.center()
        win.isReleasedWhenClosed = false
        // 关闭时只是隐藏，不销毁
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settingsWindow = nil
            }
        }
        _ = closeObserver
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - 权限

    /// 检测当前权限状态（**不调 AXIsProcessTrustedWithOptions**）。
    /// 屏幕录制权限用 SCShareableContent 探测，**不会 crash**（未授权时 throw）。
    /// 辅助功能权限用"试一次 ⌘C 模拟"探测（不调 AX API）。
    func refreshPermissions() {
        Task { @MainActor in
            self.hasScreenCapturePermission = await ScreenCapture.probePermission()
            self.hasAccessibilityPermission = await self.probeAccessibilityPermission()
        }
    }

    /// 打开系统设置到辅助功能授权页
    func requestAccessibilityPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开系统设置到屏幕录制授权页
    func requestScreenCapturePermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    private func ensurePermissionsForSelection() -> Bool {
        // 不预探测拦截（副作用探测法会误报 false，导致已授权用户每次都被弹窗）。
        // 直接放行让 simulateCopy 真正执行，失败时由 tryReadSelection 给出提示。
        if AXIsProcessTrusted() == false {
            showError("需要「辅助功能」权限才能翻译选中文本。\n请到 设置 → 隐私与安全性 → 辅助功能 勾选「Translate」。\n\n授权后请重新打开本 App。")
            requestAccessibilityPermission()
            return false
        }
        return true
    }

    @discardableResult
    private func ensurePermissionsForScreenshot() -> Bool {
        // 不依赖屏幕录制预探测（SCShareableContent 枚举在某些情况下即使已授权也会 throw，
        // 误报 false 后每次都弹设置）。直接放行，截图失败时再按 permissionDenied 分支引导。
        return true
    }

    // MARK: - 流程

    private func processScreenshot(_ image: NSImage) {
        isWorking = true
        statusMessage = "识别图中文字…"
        showResultPanel()

        Task { [weak self] in
            guard let self = self else { return }

            // 按设置走 OCR 策略
            var extractedText = ""
            let mode = self.settings.ocrMode
            do {
                switch mode {
                case .local:
                    extractedText = try await self.ocr.recognizeText(in: image)
                case .remote:
                    self.statusMessage = "发送到多模态模型识别中…"
                    return await self.runTranslateWithImage(image)
                case .both:
                    do {
                        extractedText = try await self.ocr.recognizeText(in: image)
                        if extractedText.isEmpty {
                            self.statusMessage = "本地 OCR 未识别到文字，发送图片给大模型…"
                            return await self.runTranslateWithImage(image)
                        }
                    } catch {
                        Log.ocr.error("local OCR failed: \(error.localizedDescription, privacy: .public)")
                        return await self.runTranslateWithImage(image)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.statusMessage = nil
                    self.showError("OCR 失败：\(error.localizedDescription)")
                }
                return
            }

            if extractedText.isEmpty {
                await MainActor.run {
                    self.isWorking = false
                    self.statusMessage = nil
                    self.showError("OCR 未识别到任何文字。")
                }
                return
            }

            await MainActor.run {
                self.statusMessage = "翻译中…"
            }
            self.runTranslate(text: extractedText, imageData: Self.pngData(from: image), source: .screenshot)
        }
    }

    private func runTranslateWithImage(_ image: NSImage) async {
        let data = Self.pngData(from: image)
        runTranslate(text: "", imageData: data, source: .screenshot)
    }

    private func runTranslate(text: String, imageData: Data?, source: TranslationRequest.Source) {
        // cancel 旧任务
        workingTask?.cancel()
        lastSource = source

        isWorking = true
        errorMessage = nil
        statusMessage = "翻译中…"
        showResultPanel()

        let req = TranslationRequest(
            text: text,
            sourceLang: settings.sourceLanguage,
            targetLang: settings.targetLanguage,
            imageData: imageData,
            source: source
        )

        workingTask = Task { [weak self] in
            guard let self = self else { return }
            let start = Date()
            do {
                let translated = try await self.translate.translate(req, config: self.settings.snapshot())
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isWorking = false
                    self.statusMessage = nil
                    let result = TranslationResult(
                        original: text,
                        translated: translated,
                        sourceLang: self.settings.sourceLanguage,
                        targetLang: self.settings.targetLanguage,
                        model: self.settings.model,
                        latency: Date().timeIntervalSince(start),
                        timestamp: Date(),
                        source: source
                    )
                    self.lastResult = result
                    self.refreshResultPanel()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isWorking = false
                    self.statusMessage = nil
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func showError(_ msg: String) {
        errorMessage = msg
        isWorking = false
        statusMessage = nil
        showResultPanel()
    }

    // MARK: - 悬浮窗

    func showResultPanel() {
        if resultPanel == nil {
            resultPanel = FloatingPanelController<AnyView>()
        }
        resultPanel?.show(
            { AnyView(ResultPanelView(coordinator: self)) },
            size: NSSize(width: 440, height: 160),
            pinned: resultPanelPinned
        )
    }

    func refreshResultPanel() {
        guard let panel = resultPanel else { return }
        panel.show(
            { AnyView(ResultPanelView(coordinator: self)) },
            size: NSSize(width: 440, height: 160),
            pinned: resultPanelPinned,
            keepPinned: true
        )
    }

    func dismissResultPanel() {
        resultPanel?.close()
    }

    /// 切换结果悬浮窗置顶
    func toggleResultPanelPin() {
        resultPanelPinned.toggle()
        resultPanel?.setPinned(resultPanelPinned)
    }

    // MARK: - Helpers

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func simulateCopy() {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
    }
}

// MARK: - 权限工具

extension AppCoordinator {
    /// 探测辅助功能权限：用 AXIsProcessTrusted()（无 options 版本，不发 prompt、ad-hoc 签名下安全不崩）。
    /// 不用 AXIsProcessTrustedWithOptions（那才会崩），也不用副作用探测法（不可靠）。
    fileprivate func probeAccessibilityPermission() async -> Bool {
        return AXIsProcessTrusted()
    }
}

private enum ScreenCapture {
    /// 用 SCShareableContent 探测：未授权时 throw（不会 crash）
    static func probePermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }
}
