import SwiftUI
import SwiftData

@main
struct VaultApp: App {
    @State private var dependencies: AppDependencies
    @State private var router = AppRouter()

    init() {
        // Live when a filled-in Supabase.plist is bundled; mock otherwise.
        let deps: AppDependencies
        if let config = BackendConfig.load() {
            deps = AppDependencies.makeLive(config: config)
        } else {
            deps = AppDependencies.makeMock()
        }
        _dependencies = State(initialValue: deps)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies)
                .environment(router)
                .modelContainer(dependencies.modelContainer)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}
