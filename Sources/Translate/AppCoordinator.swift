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

    private init() {
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
        // 等一下
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            guard pb.changeCount != old, let text = pb.string(forType: .string), !text.isEmpty else {
                self.showError("未检测到选中文本。请先选中要翻译的文字再按快捷键。")
                return
            }
            self.runTranslate(text: text, imageData: nil, source: .selection)
        }
    }

    /// 截图翻译
    func translateScreenshotNow() {
        guard ensurePermissionsForScreenshot() else { return }
        statusMessage = "请框选截图区域…"
        isWorking = true
        showResultPanel()

        ScreenshotOverlayController().start(screenshot: screenshot) { [weak self] image in
            guard let self = self else { return }
            guard let image = image else {
                self.isWorking = false
                self.statusMessage = nil
                self.dismissResultPanel()
                return
            }
            self.processScreenshot(image)
        }
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

    func openPreferences() {
        if #available(macOS 14, *) {
            // 触发 Settings 场景
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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
        // 不预先用 AXIsProcessTrustedWithOptions 探测（ad-hoc 签名会崩）。
        // 让 simulateCopy 试一下：失败时给用户清晰的提示。
        if hasAccessibilityPermission == false {
            // 已经探测过且失败，让用户去授权
            showError("需要「辅助功能」权限才能翻译选中文本。\n请到 设置 → 隐私与安全性 → 辅助功能 授权。\n\n授权后请重新打开本 App。")
            requestAccessibilityPermission()
            return false
        }
        return true
    }

    @discardableResult
    private func ensurePermissionsForScreenshot() -> Bool {
        if hasScreenCapturePermission == false {
            showError("需要「屏幕录制」权限才能截图翻译。\n请到 设置 → 隐私与安全性 → 屏幕录制 授权。\n\n授权后请重新打开本 App。")
            requestScreenCapturePermission()
            return false
        }
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
            size: NSSize(width: 440, height: 260)
        )
    }

    func refreshResultPanel() {
        guard let panel = resultPanel else { return }
        panel.show(
            { AnyView(ResultPanelView(coordinator: self)) },
            size: NSSize(width: 440, height: 260)
        )
    }

    func dismissResultPanel() {
        resultPanel?.close()
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
    /// 探测辅助功能权限：不调 AXIsProcessTrustedWithOptions（ad-hoc 签名会 crash）。
    /// 改用尝试模拟 ⌘C 并恢复原剪贴板的副作用探测法。
    fileprivate func probeAccessibilityPermission() async -> Bool {
        let pb = NSPasteboard.general
        let oldChangeCount = pb.changeCount
        let oldContents: String? = pb.string(forType: .string)
        let oldImageData: Data? = pb.data(forType: .tiff)

        let src = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)

        // 等待剪贴板更新
        let deadline = Date().addingTimeInterval(0.15)
        while pb.changeCount == oldChangeCount, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let changed = pb.changeCount != oldChangeCount

        // 恢复原剪贴板
        pb.clearContents()
        if let s = oldContents { pb.setString(s, forType: .string) }
        if let img = oldImageData { pb.setData(img, forType: .tiff) }
        _ = oldImageData

        return changed
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
