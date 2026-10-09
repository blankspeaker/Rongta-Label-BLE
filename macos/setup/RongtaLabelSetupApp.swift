// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct RongtaLabelSetupApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: SetupWindow.contentWidth, height: SetupWindow.contentHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Rongta Label Setup") {
                    model.section = .help
                }
            }
        }
    }
}
