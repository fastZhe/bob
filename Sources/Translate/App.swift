import SwiftUI

@main
struct TranslateApp: App {
    @StateObject private var coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            StatusBarMenu()
                .environmentObject(coordinator)
                .task { coordinator.bootstrap() }
        } label: {
            Image(systemName: "character.bubble.fill")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView(settings: coordinator.settings)
                .environmentObject(coordinator)
        }
    }
}
