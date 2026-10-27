import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var qrManager = QRLoginManager()
    @State private var showWebLogin = false
    @State private var showGuestHome = false
    @State private var webError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("贴吧")
                        .font(.largeTitle.bold())
                    Text("第三方客户端：只做阅读、发帖、回复")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let image = qrManager.qrImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                    } else if qrManager.isLoading {
                        ProgressView()
                            .frame(width: 220, height: 220)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 220, height: 220)
                            .overlay(Text("二维码").foregroundStyle(.secondary))
                    }

                    Text(qrManager.message.isEmpty ? "用百度 App / 贴吧 App 扫码并确认" : qrManager.message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button(qrManager.qrImage == nil ? "获取二维码" : "重新获取二维码") {
                        qrManager.fetchQR()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(qrManager.isLoading)

                    if qrManager.isPolling {
                        Button("取消轮询") {
                            qrManager.cancel()
                        }
                        .buttonStyle(.bordered)
                    }

                    if let webError {
                        Text(webError).foregroundStyle(.red)
                    }

                    Divider()

                    // 备用入口：网页扫码，不喧宾夺主，只放在底部。
                    Button("网页扫码（备用）") {
                        showWebLogin = true
                    }
                    .buttonStyle(.bordered)

                    Button("不登录，先逛逛") {
                        showGuestHome = true
                    }

                    Text("BDUSS 只保存在本机 Keychain，不会上传到任何服务器。退出登录即删除 BDUSS 和 STOKEN。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("登录")
            .sheet(isPresented: $showWebLogin) {
                NavigationStack {
                    WebQRLoginView { bduss, stoken in
                        _ = KeychainStore.save(account: KeychainStore.bdussAccount, value: bduss)
                        if let stoken, !stoken.isEmpty {
                            _ = KeychainStore.save(account: KeychainStore.stokenAccount, value: stoken)
                        }
                        showWebLogin = false
                        session.refresh()
                    }
                    .navigationTitle("网页扫码")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showWebLogin = false }
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showGuestHome) {
                HomeView()
            }
            .onAppear {
                qrManager.onLoggedIn = { session.refresh() }
                if qrManager.qrImage == nil && !qrManager.isLoading {
                    qrManager.fetchQR()
                }
            }
        }
    }
}

// 备用网页扫码：打开 passport 登录页（该页本身有扫码），
// 每 2 秒查一次 WKHTTPCookieStore，拿到 BDUSS 即回调并关闭。
struct WebQRLoginView: UIViewControllerRepresentable {
    var onFound: (String, String?) -> Void

    func makeUIViewController(context: Context) -> WebLoginViewController {
        let controller = WebLoginViewController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ uiViewController: WebLoginViewController, context: Context) {}
}

final class WebLoginViewController: UIViewController {
    var onFound: ((String, String?) -> Void)?
    private var webView: WKWebView?
    private var timer: Timer?
    private var hasFired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let webView = WKWebView(frame: view.bounds)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
        self.webView = webView
        if let url = URL(string: "https://passport.baidu.com/") {
            webView.load(URLRequest(url: url))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkCookies()
        }
    }

    private func checkCookies() {
        guard !hasFired, let webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.hasFired else { return }
            let bduss = cookies.first { $0.name == "BDUSS" }?.value
            let stoken = cookies.first { $0.name == "STOKEN" }?.value
            guard let bduss, !bduss.isEmpty else { return }
            self.hasFired = true
            self.timer?.invalidate()
            self.timer = nil
            DispatchQueue.main.async {
                self.onFound?(bduss, stoken)
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}
