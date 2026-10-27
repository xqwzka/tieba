import SwiftUI

// 登录态：只以 Keychain 里有没有 BDUSS 为准。
final class SessionStore: ObservableObject {
    @Published var isLoggedIn = false

    init() {
        refresh()
    }

    func refresh() {
        isLoggedIn = KeychainStore.isLoggedIn
    }

    func logout() {
        KeychainStore.deleteAllCredentials()
        isLoggedIn = false
    }
}

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
