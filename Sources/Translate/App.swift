import SwiftUI

@main
struct TranslateApp: App {
    @StateObject private var coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            StatusBarMenu(coordinator: coordinator)
                .task { coordinator.bootstrap() }
        } label: {
            Image(systemName: "character.bubble.fill")
        }
        .menuBarExtraStyle(.menu)
        // 不依赖 SwiftUI Settings scene（MenuBarExtra .menu 下 sendAction 不可靠）
    }
}
