import CryptoKit
import Foundation
import SwiftUI

// 原生扫码：取二维码 -> 轮询 unicast，BDUSS 一出现就存 Keychain。
// 返回格式不确定，所以 img/sign 在整份 JSON 里递归找，失败时显示服务端原返回前 200 字。
@MainActor
final class QRLoginManager: ObservableObject {
    @Published var qrImage: UIImage?
    @Published var message = ""
    @Published var isLoading = false
    @Published var isPolling = false

    var onLoggedIn: (() -> Void)?
    private var sign = ""
    private var pollCount = 0
    private var cancelled = false

    func cancel() {
        cancelled = true
        isPolling = false
        message = "已取消轮询"
    }

    func fetchQR() {
        cancelled = false
        isLoading = true
        message = ""
        qrImage = nil
        Task {
            do {
                // 先预取 passport 首页，拿 BAIDUID Cookie。
                var homeRequest = URLRequest(url: URL(string: "https://passport.baidu.com/")!)
                homeRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                let (_, homeResponse) = try await URLSession.shared.data(for: homeRequest)
                var cookie = ""
                if let http = homeResponse as? HTTPURLResponse,
                   let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") {
                    cookie = setCookie.components(separatedBy: ";").first ?? ""
                }
                var lastError = ""
                for params in ["tpl=pp", "tpl=tb", "qrlogin=1"] {
                    let urlString = "https://passport.baidu.com/v2/api/getqrcode?\(params)&apiver=v3&tt=\(Int(Date().timeIntervalSince1970 * 1000))&callback="
                    var request = URLRequest(url: URL(string: urlString)!)
                    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                    request.setValue("https://passport.baidu.com/", forHTTPHeaderField: "Referer")
                    if !cookie.isEmpty {
                        request.setValue(cookie, forHTTPHeaderField: "Cookie")
                    }
                    let (data, _) = try await URLSession.shared.data(for: request)
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    let jsonText = stripJSONP(text)
                    guard let jsonData = jsonText.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        lastError = String(text.prefix(200))
                        continue
                    }
                    let img = findString(in: object, keys: ["imgdata", "qrcode", "img", "image"])
                    let foundSign = findString(in: object, keys: ["sign", "uuid", "channel_id", "qrcode_sign"])
                    if let img, let foundSign, !img.isEmpty, !foundSign.isEmpty {
                        self.sign = foundSign
                        if let imageURL = URL(string: img.hasPrefix("http") ? img : "https:\(img)"),
                           let (imageData, _) = try? await URLSession.shared.data(from: imageURL),
                           let image = UIImage(data: imageData) {
                            self.qrImage = image
                        } else if let imageData = Data(base64Encoded: img),
                                  let image = UIImage(data: imageData) {
                            self.qrImage = image
                        }
                        self.isLoading = false
                        self.startPolling()
                        return
                    }
                    lastError = String(text.prefix(200))
                }
                self.isLoading = false
                self.message = lastError.isEmpty ? "获取二维码失败" : "获取二维码失败：\(lastError)"
            } catch {
                self.isLoading = false
                self.message = "获取二维码失败：\(error.localizedDescription)"
            }
        }
    }

    private func stripJSONP(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "("), let end = trimmed.lastIndex(of: ")"), start < end {
            return String(trimmed[trimmed.index(after: start)..<end])
        }
        return trimmed
    }

    private func findString(in object: Any, keys: [String]) -> String? {
        if let dict = object as? [String: Any] {
            for key in keys {
                if let value = dict[key] as? String, !value.isEmpty {
                    return value
                }
            }
            for value in dict.values {
                if let found = findString(in: value, keys: keys) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findString(in: value, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private func startPolling() {
        isPolling = true
        pollCount = 0
        message = "请用百度 App / 贴吧 App 扫码并确认"
        Task {
            while !cancelled && pollCount < 120 {
                pollCount += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if cancelled { break }
                let urlString = "https://passport.baidu.com/channel/unicast?channel_id=\(sign)&callback="
                guard let url = URL(string: urlString) else { break }
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let bduss = extractCookie(text, name: "BDUSS") ?? extractRaw(text, name: "BDUSS")
                let stoken = extractCookie(text, name: "STOKEN") ?? extractRaw(text, name: "STOKEN")
                if let bduss, !bduss.isEmpty {
                    _ = KeychainStore.save(account: KeychainStore.bdussAccount, value: bduss)
                    if let stoken, !stoken.isEmpty {
                        _ = KeychainStore.save(account: KeychainStore.stokenAccount, value: stoken)
                    }
                    isPolling = false
                    message = "登录成功"
                    onLoggedIn?()
                    return
                }
                if let http = response as? HTTPURLResponse,
                   let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
                   let bduss2 = extractCookie(setCookie, name: "BDUSS"), !bduss2.isEmpty {
                    _ = KeychainStore.save(account: KeychainStore.bdussAccount, value: bduss2)
                    isPolling = false
                    message = "登录成功"
                    onLoggedIn?()
                    return
                }
            }
            if !cancelled {
                isPolling = false
                message = "扫码超时，请重新获取二维码"
            }
        }
    }

    private func extractCookie(_ text: String, name: String) -> String? {
        let pattern = "\(name)=([^;\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func extractRaw(_ text: String, name: String) -> String? {
        let pattern = "\"\(name)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
