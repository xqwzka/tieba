import SwiftUI

// 真实头像：portrait 为空或加载失败时退回首字圆头像，不留空白。
struct AvatarView: View {
    let name: String
    let portrait: String
    var size: CGFloat = 44

    private var avatarURL: URL? {
        guard !portrait.isEmpty else { return nil }
        if portrait.hasPrefix("http") {
            return URL(string: portrait)
        }
        return URL(string: "https://tb.himg.baidu.com/sys/portrait/item/\(portrait)")
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
        if let url = avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                default:
                    fallback
                }
            }
        } else {
            fallback
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
