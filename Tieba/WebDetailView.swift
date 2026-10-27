import SwiftUI
import WebKit

// 详情网页版：原生接口拿不到楼层时的兜底，直接打开官方帖子页。
// 用默认 WKWebView 数据存储，与网页扫码登录共用 Cookie，登录后也是登录态。
// 不做任何解析，楼层、作者、头像以官方页面为准。
struct WebDetailView: View {
    let tid: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebView(url: URL(string: "https://tieba.baidu.com/p/\(tid)"))
                .navigationTitle("网页版详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url, webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }
}
