import SwiftUI
import UIKit

@main
struct StenoApp: App {
    // Process-wide, not per scene: two iPad windows share one library and one
    // set of running jobs.
    @State private var model = AppModel()
    @State private var textModels = TextModelSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(textModels)
                .task { await model.bootstrap() }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didEnterBackgroundNotification
                    )
                ) { _ in
                    Task { await model.cancelDiarizationModelInstallForBackground() }
                }
        }
    }
}
