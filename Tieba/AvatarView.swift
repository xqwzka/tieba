import SwiftUI

// 真实头像：portrait 为空或加载失败时退回首字圆头像，不留空白。
// 不用 AsyncImage：贴吧头像域名对直接请求会拦（浏览器里 https 报证书名不匹配、
// http 直接是空白错误页，网页版帖子页里头像能显示是因为请求带了贴吧来源），
// 所以这里用 URLSession 带 Referer 去取，https 不行再试 http。
struct AvatarView: View {
    let name: String
    let portrait: String
    var size: CGFloat = 44

    @State private var image: UIImage?

    private var candidates: [URL] {
        guard !portrait.isEmpty else { return [] }
        if portrait.hasPrefix("http") {
            return [URL(string: portrait)].compactMap { $0 }
        }
        // portrait 实测会带 ?t= 时间戳后缀（如 tb.1.xxx?t=1793...），那是缓存参数不是头像 id；
        // 直接拼进路径会让头像地址带上多余查询，剥掉后再拼才是用户原本的头像地址。
        let clean = portrait.split(separator: "?", maxSplits: 1).first.map(String.init) ?? portrait
        return [
            URL(string: "https://tb.himg.baidu.com/sys/portrait/item/\(clean)"),
            URL(string: "http://tb.himg.baidu.com/sys/portrait/item/\(clean)"),
        ].compactMap { $0 }
    }

    private var fallback: some View {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .red, .brown]
        let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let initial = name.isEmpty ? "?" : String(name.prefix(1))
        return Text(initial)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(palette[abs(hash) % palette.count].opacity(0.8)))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                fallback
            }
        }
        .task(id: portrait) {
            image = nil
            for url in candidates {
                var request = URLRequest(url: url)
                request.setValue("https://tieba.baidu.com/", forHTTPHeaderField: "Referer")
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let loaded = UIImage(data: data) else { continue }
                image = loaded
                return
            }
        }
    }
}

func formatTiebaTime(_ timestamp: Int) -> String {
    guard timestamp > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
}

func relativeTiebaTime(_ timestamp: Int) -> String {
    guard timestamp > 0 else { return "" }
    let seconds = Int(Date().timeIntervalSince1970) - timestamp
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86400 { return "\(seconds / 3600) 小时前" }
    return formatTiebaTime(timestamp)
}

func countText(_ value: Int) -> String {
    if value >= 10000 {
        return String(format: "%.1fk", Double(value) / 1000.0)
    }
    return "\(value)"
}
