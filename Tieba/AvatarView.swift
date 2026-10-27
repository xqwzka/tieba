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

    private var palette: [Color] {
        [.orange, .blue, .green, .purple, .pink, .teal, .red, .brown]
    }

    private var fallback: some View {
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
