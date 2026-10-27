import Foundation
import UIKit

// 原生扫码登录：取二维码 -> 轮询 unicast，BDUSS 一出现就存 Keychain。
// 注意：轮询返回格式未经真机验证，是本 App 最不确定的环节，见 README。
final class QRLoginManager: ObservableObject {
    @Published var qrImage: UIImage?
    @Published var message = ""
    @Published var isLoading = false
    @Published var isPolling = false

    var onLoggedIn: (() -> Void)?
    private var pollTask: Task<Void, Never>?

    deinit {
        pollTask?.cancel()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func fetchQR() {
        cancel()
        isLoading = true
        message = "正在获取二维码…"
        qrImage = nil
        Task { @MainActor in
            do {
                let (image, sign) = try await fetchQRCode()
                self.qrImage = image
                self.isLoading = false
                self.message = "用百度 App / 贴吧 App 扫码并确认"
                self.startPolling(sign: sign)
            } catch {
                self.isLoading = false
                self.message = "获取二维码失败：\(error.localizedDescription)"
            }
        }
    }

    // GET passport.baidu.com/v2/api/getqrcode，data.imgdata 为 base64 图片，data.sign 用于轮询。
    private func fetchQRCode() async throws -> (UIImage, String) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "https://passport.baidu.com/v2/api/getqrcode?lp=pc&apiver=v3&tpl=pp&tt=\(timestamp)") else {
            throw TiebaError.invalidResponse
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw TiebaError.network(error.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = object["data"] as? [String: Any],
              let imgdata = dataObject["imgdata"] as? String,
              let sign = dataObject["sign"] as? String, !sign.isEmpty else {
            throw TiebaError.invalidResponse
        }
        // imgdata 可能是裸 base64，也可能是 data:image/png;base64,... 形式。
        let base64 = imgdata.contains(",") ? String(imgdata.split(separator: ",", maxSplits: 1).last ?? "") : imgdata
        guard let imageData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: imageData) else {
            throw TiebaError.invalidResponse
        }
        return (image, sign)
    }

    private func startPolling(sign: String) {
        isPolling = true
        pollTask = Task { @MainActor in
            for _ in 0..<120 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                if let credentials = try? await self.pollOnce(sign: sign) {
                    _ = KeychainStore.save(account: KeychainStore.bdussAccount, value: credentials.bduss)
                    if let stoken = credentials.stoken, !stoken.isEmpty {
                        _ = KeychainStore.save(account: KeychainStore.stokenAccount, value: stoken)
                    }
                    self.isPolling = false
                    self.message = "已登录"
                    self.onLoggedIn?()
                    return
                }
            }
            if !Task.isCancelled {
                self.isPolling = false
                self.message = "二维码已过期，请重新获取二维码"
            }
        }
    }

    // 轮询 passport.baidu.com/channel/unicast?channel_id=<sign>。
    // BDUSS 可能出现在 JSON 体里，也可能出现在 Set-Cookie 里，两处都查。
    private func pollOnce(sign: String) async throws -> (bduss: String, stoken: String?)? {
        guard let url = URL(string: "https://passport.baidu.com/channel/unicast?channel_id=\(sign)") else {
            return nil
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            return nil
        }
        var bduss: String?
        var stoken: String?
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                guard let keyText = key as? String, keyText.lowercased() == "set-cookie",
                      let cookieText = value as? String else { continue }
                if bduss == nil { bduss = cookieValue(in: cookieText, name: "BDUSS") }
                if stoken == nil { stoken = cookieValue(in: cookieText, name: "STOKEN") }
            }
        }
        if bduss == nil, let bodyText = String(data: data, encoding: .utf8) {
            bduss = extractFromRaw(bodyText, name: "BDUSS")
            stoken = extractFromRaw(bodyText, name: "STOKEN")
        }
        if bduss == nil,
           let object = try? JSONSerialization.jsonObject(with: data) {
            bduss = findValue(in: object, key: "bduss")
            stoken = findValue(in: object, key: "stoken")
        }
        guard let found = bduss, !found.isEmpty else { return nil }
        return (found, stoken)
    }

    private func cookieValue(in cookieText: String, name: String) -> String? {
        // Set-Cookie 形如 "BDUSS=xxx; path=/; ..."：只取第一个分号前的键值对。
        let first = cookieText.split(separator: ";", maxSplits: 1).first ?? ""
        let pair = first.split(separator: "=", maxSplits: 1)
        guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name else {
            return nil
        }
        let value = pair[1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func extractFromRaw(_ text: String, name: String) -> String? {
        guard let range = text.range(of: "\(name)=") else { return nil }
        let rest = text[range.upperBound...]
        let delimiters: Set<Character> = [";", "&", "\"", "'", ",", " ", "\n", "\r", "}"]
        let value = rest.prefix(while: { !delimiters.contains($0) })
        return value.isEmpty ? nil : String(value)
    }

    private func findValue(in object: Any, key target: String) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if key.lowercased() == target, let text = value as? String, !text.isEmpty {
                    return text
                }
                if let found = findValue(in: value, key: target) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findValue(in: value, key: target) { return found }
            }
        }
        return nil
    }
}
