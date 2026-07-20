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

    @Published var hasAccessibilityPermission = false
    @Published var hasScreenCapturePermission = false

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
        // 注意：refreshPermissions() 不能在这里调 —— ad-hoc 签名 + init 阶段调 AXIsProcessTrustedWithOptions
        // 会导致 SIGSEGV（在 CFGetTypeID 处）。延后到 .task / .onAppear 里调。
    }

    /// 在 SwiftUI scene 已构建后调用一次。Scene 出现后调一次。
    func bootstrap() {
        Task { @MainActor in
            // 等 SwiftUI 完全挂载（避免 init 阶段触发 AX API crash）
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.refreshPermissions()
        }
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

    func refreshPermissions() {
        hasAccessibilityPermission = Accessibility.isTrusted(prompt: false)
        hasScreenCapturePermission = ScreenCapture.hasPermission()
    }

    func requestAccessibilityPermission() {
        _ = Accessibility.isTrusted(prompt: true)
        // 用户在系统设置里改完回来再刷新
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func requestScreenCapturePermission() {
        ScreenCapture.requestPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissions()
        }
    }

    @discardableResult
    private func ensurePermissionsForSelection() -> Bool {
        if !hasAccessibilityPermission {
            showError("需要「辅助功能」权限才能翻译选中文本。\n请到 设置 → 隐私与安全性 → 辅助功能 授权。")
            requestAccessibilityPermission()
            return false
        }
        return true
    }

    @discardableResult
    private func ensurePermissionsForScreenshot() -> Bool {
        if !hasScreenCapturePermission {
            showError("需要「屏幕录制」权限才能截图翻译。\n请到 设置 → 隐私与安全性 → 屏幕录制 授权。")
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

private enum Accessibility {
    static func isTrusted(prompt: Bool) -> Bool {
        let options: [String: Any] = prompt ? [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] : [:]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

private enum ScreenCapture {
    /// 主动触发一次截屏来让 macOS 弹出权限对话框
    static func requestPermission() {
        Task {
            do {
                _ = try await ScreenshotService().captureFullScreen()
            } catch {
                Log.screen.info("triggered permission dialog: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 推断：能拿到 display 就算有权限（粗略）
    static func hasPermission() -> Bool {
        let box = BoolBox(false)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                box.value = !content.displays.isEmpty
            } catch {
                box.value = false
            }
        }
        _ = sem.wait(timeout: .now() + 1.0)
        return box.value
    }
}

/// 简单可变的 Bool 容器，用于跨并发闭包传递值。
private final class BoolBox: @unchecked Sendable {
    var value: Bool
    init(_ v: Bool) { self.value = v }
}
