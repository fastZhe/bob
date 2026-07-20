import SwiftUI

/// 菜单栏下拉菜单
struct StatusBarMenu: View {
    /// 直接传 coordinator，不依赖 EnvironmentObject（MenuBarExtra .menu 样式对 EnvironmentObject 兼容性差）
    let coordinator: AppCoordinator

    var body: some View {
        Button {
            coordinator.translateSelectionNow()
        } label: {
            Label("翻译选中文本", systemImage: "character.cursor.ibeam")
        }

        Button {
            coordinator.translateScreenshotNow()
        } label: {
            Label("截图翻译", systemImage: "camera.viewfinder")
        }

        Button {
            coordinator.translateClipboardNow()
        } label: {
            Label("剪贴板翻译", systemImage: "doc.on.clipboard")
        }

        Divider()

        Button {
            coordinator.openPreferences()
        } label: {
            Label("设置…", systemImage: "gearshape")
        }

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
    }
}
