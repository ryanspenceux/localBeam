import SwiftUI

@main
struct LocalBeamApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 600, height: 450)
    }
}
