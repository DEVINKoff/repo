import SwiftUI

@main
struct BlendPaintApp: App {
    @State var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
