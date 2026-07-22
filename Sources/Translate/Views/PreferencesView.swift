import SwiftUI
import KeyboardShortcuts

/// 设置面板
struct PreferencesView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gearshape") }
            hotkeyTab.tabItem { Label("快捷键", systemImage: "keyboard") }
            screenshotTab.tabItem { Label("截图翻译", systemImage: "camera.viewfinder") }
            advancedTab.tabItem { Label("高级", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 580, height: 460)
        .padding(8)
        .onAppear { coordinator.refreshPermissions() }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section {
                Picker("预设", selection: presetBinding) {
                    Text("自定义").tag(Optional<String>.none)
                    ForEach(SettingsStore.presets) { p in
                        Text(p.name).tag(Optional(p.name))
                    }
                }
            }

            Section("OpenAI 兼容接口") {
                LabeledContent("Base URL") {
                    TextField("", text: $settings.apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API Key") {
                    SecureField("", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Model") {
                    TextField("", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                }
                Text("支持 LM Studio、Ollama、OpenAI、DeepSeek、SiliconFlow、Moonshot 等所有 OpenAI 兼容 chat 接口。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("语言") {
                Picker("源语言", selection: $settings.sourceLanguage) {
                    ForEach(SettingsStore.languages, id: \.code) { l in
                        Text(l.label).tag(l.code)
                    }
                }
                Picker("目标语言", selection: $settings.targetLanguage) {
                    ForEach(SettingsStore.languages.filter { $0.code != "auto" }, id: \.code) { l in
                        Text(l.label).tag(l.code)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 快捷键

    private var hotkeyTab: some View {
        Form {
            Section("全局快捷键（在系统任意位置生效）") {
                KeyboardShortcuts.Recorder(for: .translateSelection) {
                    Text("选中文本翻译：")
                }
                KeyboardShortcuts.Recorder(for: .translateScreenshot) {
                    Text("截图翻译：")
                }
                KeyboardShortcuts.Recorder(for: .translateClipboard) {
                    Text("剪贴板翻译：")
                }
                Text("默认：⌃⌥⌘D 选中文本 / ⌘⌥⇧S 截图 / ⌃⌥⌘V 剪贴板。可在录制框中按下新组合键覆盖。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("权限") {
                permissionRow(
                    "辅助功能",
                    status: coordinator.hasAccessibilityPermission,
                    request: { coordinator.requestAccessibilityPermission() },
                    help: "选中文本翻译依赖此权限。未授权时，选中文字后按快捷键会显示「未检测到选中文本」。"
                )
                permissionRow(
                    "屏幕录制",
                    status: coordinator.hasScreenCapturePermission,
                    request: { coordinator.requestScreenCapturePermission() },
                    help: "截图翻译依赖此权限。未授权时，截图会提示权限错误。"
                )
                Button {
                    coordinator.refreshPermissions()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Text("提示：辅助功能权限用 AXIsProcessTrusted() 探测；屏幕录制权限用 SCShareableContent 探测，未授权或偶发异常时可能误报未授权。点「去授权」打开系统设置，授权后回到此处点「重新检测」验证。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(_ name: String, status: Bool?, request: @escaping () -> Void, help: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon(status))
                .foregroundColor(statusColor(status))
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundColor(statusColor(status))
                }
                Text(help).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("去授权") { request() }
        }
        .padding(.vertical, 4)
    }

    private func statusIcon(_ status: Bool?) -> String {
        switch status {
        case .some(true):  return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none:        return "questionmark.circle.fill"
        }
    }

    private func statusColor(_ status: Bool?) -> Color {
        switch status {
        case .some(true):  return .green
        case .some(false): return .orange
        case .none:        return .secondary
        }
    }

    private func statusText(_ status: Bool?) -> String {
        switch status {
        case .some(true):  return "已授权"
        case .some(false): return "未授权"
        case .none:        return "未检测"
        }
    }

    // MARK: - 截图翻译

    private var screenshotTab: some View {
        Form {
            Section("OCR 模式") {
                Picker("OCR 模式", selection: $settings.ocrMode) {
                    ForEach(OCRMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 6) {
                    bulletRow("本地 Vision：免费、离线、Mac 原生。识别不到时降级到远程（仅「本地优先」模式）。")
                    bulletRow("多模态大模型：直接把图片发给模型（需支持 vision 的模型，如 GPT-4o、Qwen2-VL、Qwen2.5-VL、Llama 3.2 Vision 等）。")
                    bulletRow("本地优先：先本地 OCR 拿文字，识别为空/失败再发图片给大模型。推荐使用。")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }

    // MARK: - 高级

    private var advancedTab: some View {
        Form {
            Section("请求") {
                LabeledContent("超时 (秒)") {
                    TextField("", value: $settings.requestTimeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
            Section("自定义系统提示词") {
                TextEditor(text: $settings.systemPromptAddition)
                    .font(.system(size: 12))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                Text("追加到默认系统提示词之后，用于风格定制（如“保持口语化”、“使用专业术语”等）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("诊断") {
                Button("检查权限") {
                    coordinator.refreshPermissions()
                }
                Button("在 Finder 中显示数据目录") {
                    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("Translate", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 预设联动

    private var presetBinding: Binding<String?> {
        Binding<String?>(
            get: { nil },
            set: { name in
                guard let name = name, let p = SettingsStore.presets.first(where: { $0.name == name }) else { return }
                settings.apiBaseURL = p.base
                if !p.key.isEmpty { settings.apiKey = p.key }
                settings.model = p.model
            }
        )
    }
}
