import SwiftUI

@main
struct SlideshowApp: App {
    @StateObject private var store = CatalogStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .task { await store.start() }
        }
    }
}
