import Foundation
import SwiftUI

/// 给 TranslateService 用的不可变配置快照（Sendable，actor 内部安全）
struct TranslateConfig: Sendable {
    let apiBaseURL: String
    let apiKey: String
    let model: String
    let sourceLanguage: String
    let targetLanguage: String
    let requestTimeout: Double
    let systemPromptAddition: String
}

/// 截图 OCR 模式
enum OCRMode: String, CaseIterable, Identifiable {
    case local    // 本地 Vision（免费、离线）
    case remote   // 把图直接发给多模态大模型
    case both     // 本地优先，失败/空时降级到远程

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:  return "本地 Vision"
        case .remote: return "多模态大模型"
        case .both:   return "本地优先"
        }
    }
}

/// 翻译服务配置。UserDefaults 持久化。
@MainActor
final class SettingsStore: ObservableObject {

    @Published var apiBaseURL: String { didSet { defaults.set(apiBaseURL, forKey: "apiBaseURL") } }
    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: "apiKey") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }

    @Published var sourceLanguage: String { didSet { defaults.set(sourceLanguage, forKey: "sourceLanguage") } }
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: "targetLanguage") } }

    @Published var ocrMode: OCRMode { didSet { defaults.set(ocrMode.rawValue, forKey: "ocrMode") } }

    @Published var requestTimeout: Double { didSet { defaults.set(requestTimeout, forKey: "requestTimeout") } }
    @Published var systemPromptAddition: String { didSet { defaults.set(systemPromptAddition, forKey: "systemPromptAddition") } }

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        self.apiBaseURL           = d.string(forKey: "apiBaseURL") ?? "http://localhost:1234/v1"
        self.apiKey               = d.string(forKey: "apiKey") ?? "lm-studio"
        self.model                = d.string(forKey: "model") ?? "qwen2.5-7b-instruct"
        self.sourceLanguage       = d.string(forKey: "sourceLanguage") ?? "auto"
        self.targetLanguage       = d.string(forKey: "targetLanguage") ?? "zh-Hans"
        self.ocrMode              = OCRMode(rawValue: d.string(forKey: "ocrMode") ?? "local") ?? .local
        self.requestTimeout       = d.double(forKey: "requestTimeout") == 0 ? 60 : d.double(forKey: "requestTimeout")
        self.systemPromptAddition = d.string(forKey: "systemPromptAddition") ?? ""
    }

    /// 不可变快照，actor 间传递
    func snapshot() -> TranslateConfig {
        TranslateConfig(
            apiBaseURL: apiBaseURL,
            apiKey: apiKey,
            model: model,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            requestTimeout: requestTimeout,
            systemPromptAddition: systemPromptAddition
        )
    }

    /// 常用预设
    static let presets: [Preset] = [
        Preset(name: "LM Studio (本地)", base: "http://localhost:1234/v1", model: "qwen2.5-7b-instruct", key: "lm-studio"),
        Preset(name: "Ollama", base: "http://localhost:11434/v1", model: "qwen2.5:7b", key: "ollama"),
        Preset(name: "OpenAI", base: "https://api.openai.com/v1", model: "gpt-4o-mini", key: ""),
        Preset(name: "DeepSeek", base: "https://api.deepseek.com/v1", model: "deepseek-chat", key: ""),
        Preset(name: "硅基流动 (SiliconFlow)", base: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct", key: ""),
        Preset(name: "月之暗面 Moonshot", base: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k", key: ""),
    ]

    struct Preset: Identifiable, Hashable {
        let name: String
        let base: String
        let model: String
        let key: String
        var id: String { name }
    }

    /// 全部语言（标签、code）
    static let languages: [(label: String, code: String)] = [
        ("自动检测",       "auto"),
        ("中文（简体）",   "zh-Hans"),
        ("中文（繁体）",   "zh-Hant"),
        ("英语",           "en"),
        ("日语",           "ja"),
        ("韩语",           "ko"),
        ("法语",           "fr"),
        ("德语",           "de"),
        ("俄语",           "ru"),
        ("西班牙语",       "es"),
        ("意大利语",       "it"),
        ("葡萄牙语",       "pt"),
    ]
}
