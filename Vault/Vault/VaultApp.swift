import SwiftUI
import SwiftData

@main
struct VaultApp: App {
    @State private var dependencies: AppDependencies
    @State private var router = AppRouter()

    init() {
        _dependencies = State(initialValue: AppDependencies.makeMock())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies)
                .environment(router)
                .modelContainer(dependencies.modelContainer)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
