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

    // GET passport.baidu.com/v2/api/getqrcode。
    // 上一版只认 data.imgdata + data.sign 两种字段，真机上服务端返回格式一变就报
    // “返回数据无法解析”。这一版：先拿一次 passport 首页让 Cookie（BAIDUID）落袋，
    // 再按多组参数依次尝试；img/sign 在整份 JSON 里递归找，不再只看 data 层；
    // 失败时把服务端原返回的前 200 字带出来，不再只给一句笼统报错。
    private func fetchQRCode() async throws -> (UIImage, String) {
        // 预取首页 Cookie，失败忽略，不阻塞扫码。
        if let home = URL(string: "https://passport.baidu.com/") {
            _ = try? await URLSession.shared.data(from: home)
        }
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let paramSets = [
            "lp=pc&apiver=v3&tpl=pp",
            "lp=pc&apiver=v3&tpl=tb",
            "lp=pc&qrlogin=1&apiver=v3&tpl=pp",
        ]
        var lastError = "扫码接口无返回"
        for params in paramSets {
            guard let url = URL(string: "https://passport.baidu.com/v2/api/getqrcode?\(params)&tt=\(timestamp)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            request.setValue("https://passport.baidu.com/", forHTTPHeaderField: "Referer")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                lastError = "网络请求失败：\(error.localizedDescription)"
                continue
            }
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                lastError = "扫码接口直接返回了图片，没有给轮询用的 sign，请改用下方网页扫码"
                continue
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let jsonText = stripJSONP(bodyText)
            guard let jsonData = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData) else {
                lastError = "扫码接口返回非 JSON：\(snippet(bodyText))"
                continue
            }
            // 服务端报错先原样透传，不再当成“无法解析”。
            if let errNo = findInt(in: object, keys: ["err_no", "errno", "error_code", "errNo"]),
               errNo != 0 {
                let msg = findValue(in: object, key: "err_msg")
                    ?? findValue(in: object, key: "msg")
                    ?? "扫码接口报错（\(errNo)）"
                lastError = msg
                continue
            }
            guard let imgString = findValue(in: object, key: "imgdata")
                    ?? findValue(in: object, key: "qrcode")
                    ?? findValue(in: object, key: "img")
                    ?? findValue(in: object, key: "image"),
                  let sign = findValue(in: object, key: "sign")
                    ?? findValue(in: object, key: "uuid")
                    ?? findValue(in: object, key: "channel_id")
                    ?? findValue(in: object, key: "qrcode_sign"),
                  !sign.isEmpty else {
                lastError = "扫码接口返回无法解析：\(snippet(bodyText))，请改用下方网页扫码"
                continue
            }
            // img 可能是图片 URL，不是 base64。
            if imgString.hasPrefix("http"), let imgURL = URL(string: imgString),
               let (imgData, _) = try? await URLSession.shared.data(from: imgURL),
               let image = UIImage(data: imgData) {
                return (image, sign)
            }
            let base64 = imgString.contains(",")
                ? String(imgString.split(separator: ",", maxSplits: 1).last ?? "")
                : imgString
            let normalized = base64
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            guard let imageData = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters),
                  let image = UIImage(data: imageData) else {
                lastError = "二维码图片解码失败，请改用下方网页扫码"
                continue
            }
            return (image, sign)
        }
        throw TiebaError.server(lastError)
    }

    private func stripJSONP(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
            return trimmed
        }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return String(inner)
    }

    private func snippet(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(cleaned.prefix(200))
    }

    private func findInt(in object: Any, keys: [String]) -> Int? {
        if let dict = object as? [String: Any] {
            for key in keys {
                if let number = dict[key] as? Int { return number }
                if let text = dict[key] as? String, let number = Int(text) { return number }
            }
            for value in dict.values {
                if let found = findInt(in: value, keys: keys) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findInt(in: value, keys: keys) { return found }
            }
        }
        return nil
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
