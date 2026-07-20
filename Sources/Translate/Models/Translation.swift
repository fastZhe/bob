import Foundation

/// 翻译请求
struct TranslationRequest {
    var text: String
    var sourceLang: String
    var targetLang: String
    /// 截图翻译时附带的图片（PNG data）
    var imageData: Data?
    /// 标识调用来源（影响提示词）
    var source: Source = .selection

    enum Source {
        case selection  // 选中文本
        case clipboard  // 剪贴板
        case screenshot // 截图
    }
}

/// 翻译结果（用于 UI 展示）
struct TranslationResult: Identifiable {
    let id = UUID()
    let original: String
    let translated: String
    let sourceLang: String
    let targetLang: String
    let model: String
    let latency: TimeInterval
    let timestamp: Date
    let source: TranslationRequest.Source
}
