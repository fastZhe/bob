import SwiftUI

/// 菜单栏下拉菜单
struct StatusBarMenu: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        Button {
            coordinator.translateSelectionNow()
        } label: {
            Label("翻译选中文本", systemImage: "character.cursor.ibeam")
        }
        .keyboardShortcut("d", modifiers: [.command, .option, .control])

        Button {
            coordinator.translateScreenshotNow()
        } label: {
            Label("截图翻译", systemImage: "camera.viewfinder")
        }
        .keyboardShortcut("s", modifiers: [.command, .option, .shift])

        Button {
            coordinator.translateClipboardNow()
        } label: {
            Label("剪贴板翻译", systemImage: "doc.on.clipboard")
        }
        .keyboardShortcut("v", modifiers: [.command, .option, .control])

        Divider()

        Button {
            coordinator.openPreferences()
        } label: {
            Label("设置…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Text("Translate 0.1.0")
            .font(.system(size: 10))
            .foregroundColor(.secondary)

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("退出", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
