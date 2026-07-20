# Translate

macOS 原生翻译软件，仿 Bob 风格。SwiftUI + AppKit 实现。

## 功能

- **选中翻译**：按快捷键自动读取当前选中文本，调用大模型翻译，悬浮窗显示结果
- **截图翻译**：按快捷键 → 框选屏幕区域 → 本地 Vision OCR / 多模态大模型 → 翻译
- **剪贴板翻译**：翻译剪贴板里已有的内容
- **菜单栏常驻**：bob 风格气泡图标，菜单栏下拉菜单
- **OpenAI 兼容**：支持 LM Studio / Ollama / OpenAI / DeepSeek / SiliconFlow / Moonshot / 自定义任何兼容 OpenAI chat 接口的服务
- **多模态**：截图模式下可选本地 OCR（免费离线）或直接发图给多模态大模型（GPT-4o / Qwen2-VL / Llama 3.2 Vision 等）

## 界面风格

- 菜单栏图标 + 下拉菜单
- 悬浮翻译结果窗：圆角 + 磨砂背景 + 居中显示，仿 bob
- 截图选区：全屏遮罩 + 挖空选区 + 角点 + 尺寸标签
- 设置面板：原生 Tabbed Preferences 风格

## 默认快捷键

| 动作 | 快捷键 |
|------|--------|
| 选中文本翻译 | ⌃⌥⌘D |
| 截图翻译 | ⌘⌥⇧S |
| 剪贴板翻译 | ⌃⌥⌘V |

可在「设置 → 快捷键」中录制自定义。

## 系统要求

- macOS 14.0 (Sonoma) 及以上
- Xcode 16+（开发）
- 运行时权限：
  - **辅助功能**（翻译选中文本）
  - **屏幕录制**（截图翻译）

## 快速开始

```bash
# 1. 开发运行
swift run

# 2. 打包 .app
./scripts/make-app.sh           # release
./scripts/make-app.sh debug     # debug

# 3. 启动
open build/Translate.app
```

## 第一次使用

1. 启动后菜单栏右上角会出现一个气泡图标
2. 点击菜单栏图标 → 「设置...」
3. 在「通用」标签选预设（如「LM Studio (本地)」）或填自定义：
   - Base URL: 你的 OpenAI 兼容服务地址
   - API Key: 对应 key（本地一般填任意非空字符串）
   - Model: 模型名
4. 在「快捷键」标签给三项操作各授权一次系统权限
5. 在「截图翻译」标签选 OCR 模式（推荐「本地优先」）
6. 选中任意文本，按 ⌃⌥⌘D，悬浮窗出翻译

## LM Studio 配置

1. 打开 LM Studio → 启动 local server（默认 `http://localhost:1234/v1`）
2. 加载一个 instruct 模型（推荐 `qwen2.5-7b-instruct`）
3. 启动 Translate → 选「LM Studio (本地)」预设 → 直接用

## Ollama 配置

1. `ollama pull qwen2.5:7b`
2. Ollama 监听 `http://localhost:11434`
3. Translate → 选「Ollama」预设

## 项目结构

```
translate/
├── Package.swift
├── Sources/Translate/
│   ├── App.swift                      # 主入口（MenuBarExtra + Settings）
│   ├── AppCoordinator.swift           # 全局协调器
│   ├── Models/
│   │   ├── Settings.swift             # 配置 + 持久化
│   │   └── Translation.swift          # 翻译请求/响应
│   ├── Services/
│   │   ├── TranslateService.swift     # OpenAI 兼容 HTTP 客户端
│   │   ├── HotKeyService.swift        # 全局快捷键（KeyboardShortcuts）
│   │   ├── SelectionMonitor.swift     # 鼠标抬起监听 + 模拟 ⌘C
│   │   ├── ScreenshotService.swift    # ScreenCaptureKit 截屏
│   │   └── OCRService.swift           # Vision 本地 OCR
│   ├── Views/
│   │   ├── StatusBarMenu.swift        # 菜单栏下拉菜单
│   │   ├── PreferencesView.swift      # 设置面板
│   │   ├── ResultPanel.swift          # 翻译结果悬浮窗
│   │   └── ScreenshotOverlay.swift    # 截图选区 UI
│   ├── Utilities/
│   │   ├── FloatingPanel.swift        # 自定义 NSPanel（圆角磨砂）
│   │   └── Logger.swift               # os.Logger
│   └── Resources/
│       └── Info.plist
└── scripts/
    └── make-app.sh                    # 打包 .app 脚本
```

## 已知限制

- 第一次启动会弹两个权限请求（辅助功能 + 屏幕录制），必须在「系统设置 → 隐私与安全性」授权
- 屏幕录制权限可能需要退出重进 app 才生效
- SwiftUI 在 NSPanel/hudWindow 上有少量边界 bug（如部分透明度），已用 NSVisualEffectView 兜底
- 暂时没有翻译历史（待办）

## License

MIT
