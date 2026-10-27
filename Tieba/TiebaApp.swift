import SwiftUI

@main
struct TiebaApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isLoggedIn {
                    HomeView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
        }
    }
}

final class SessionStore: ObservableObject {
    @Published var isLoggedIn = false

    init() { refresh() }

    func refresh() {
        isLoggedIn = KeychainStore.isLoggedIn
    }

    func logout() {
        KeychainStore.clear()
        isLoggedIn = false
    }
}
