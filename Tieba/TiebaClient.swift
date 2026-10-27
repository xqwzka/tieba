import CryptoKit
import Foundation

// 接口适配层：所有贴吧请求、签名、解析只在这里。
// 全部请求直连贴吧，不经过任何自有服务器；凭证只存 Keychain，不打日志。
// 不伪造设备指纹，不带 cuid；标准 UA；发帖/回复间隔不少于 5 秒；列表/详情缓存 60 秒。
@MainActor
final class TiebaClient {
    static let shared = TiebaClient()
    private init() {}

    private let baseURL = "https://c.tieba.baidu.com"
    private let clientVersion = "12.51.7.1"
    private var writeInFlight = false
    private var lastSubmitAt: Date?
    private var threadsCache: [String: (Date, ForumThreads)] = [:]
    private var postsCache: [String: (Date, [TiebaPost])] = [:]

    static func sign(_ params: [String: String]) -> String {
        let base = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined() + "tiebaclient!!!"
        let digest = Insecure.MD5.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var cookieHeader: String? {
        guard let bduss = KeychainStore.bduss, !bduss.isEmpty else { return nil }
        if let stoken = KeychainStore.stoken, !stoken.isEmpty {
            return "BDUSS=\(bduss); STOKEN=\(stoken)"
        }
        return "BDUSS=\(bduss)"
    }

    private func signedParams(_ params: [String: String]) -> [String: String] {
        var signed = params
        signed["_client_type"] = "2"
        signed["_client_version"] = clientVersion
        signed["sign"] = Self.sign(signed)
        return signed
    }

    private func request(path: String, params: [String: String], method: String) async throws -> Data {
        let signed = signedParams(params)
        var urlRequest: URLRequest
        if method == "GET" {
            var components = URLComponents(string: baseURL + path)
            components?.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components?.url else { throw TiebaError.invalidResponse }
            urlRequest = URLRequest(url: url)
        } else {
            guard let url = URL(string: baseURL + path) else { throw TiebaError.invalidResponse }
            urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            var components = URLComponents()
            components.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
            urlRequest.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        urlRequest.httpMethod = method
        if let cookie = cookieHeader {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TiebaError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try checkError(in: data)
            throw TiebaError.server("贴吧返回 HTTP \(http.statusCode)")
        }
        try checkError(in: data)
        return data
    }

    @discardableResult
    private func checkError(in data: Data) throws -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        if let code = jsonInt(object["error_code"]), code != 0 {
            throw TiebaError.server(Self.friendlyError(code: code, message: jsonString(object["error_msg"])))
        }
        return true
    }

    static func friendlyError(code: Int, message: String) -> String {
        if message.contains("验证码") || message.contains("captcha") {
            return "需要验证码：请到官方贴吧完成验证后再试，本 App 不自动识别验证码。原错：\(message)"
        }
        if message.contains("禁言") || message.contains("封禁") {
            return "账号被禁言或封禁，暂时无法发言。原错：\(message)"
        }
        if message.contains("频率") || message.contains("太快") || message.contains("频繁") {
            return "提交太频繁，请等一会儿再试。原错：\(message)"
        }
        if message.contains("登录") || code == 110001 {
            return "登录已失效或未登录，请重新扫码登录。原错：\(message)"
        }
        if message.contains("违规") || message.contains("敏感") {
            return "内容可能违规，请修改后再提交。原错：\(message)"
        }
        return message.isEmpty ? "贴吧返回错误（\(code)）" : message
    }

    private func jsonInt(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        if let number = value as? Double { return Int(number) }
        return nil
    }

    private func jsonString(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        return ""
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TiebaError.invalidResponse
        }
    }

    private func applyUsers(_ users: [AuthorInfo]?, to threads: inout [TiebaThread]) {
        guard let users, !users.isEmpty else { return }
        let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, AuthorInfo)? in
            guard !user.id.isEmpty else { return nil }
            return (user.id, user)
        })
        for index in threads.indices {
            guard let user = byId[threads[index].authorId] else { continue }
            if threads[index].authorName == "未知用户" || threads[index].authorName.isEmpty, !user.name.isEmpty {
                threads[index].authorName = user.name
            }
            if threads[index].authorPortrait.isEmpty {
                threads[index].authorPortrait = user.portrait
            }
        }
    }

    private func applyUsers(_ users: [AuthorInfo]?, to posts: inout [TiebaPost]) {
        guard let users, !users.isEmpty else { return }
        let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, AuthorInfo)? in
            guard !user.id.isEmpty else { return nil }
            return (user.id, user)
        })
        for index in posts.indices {
            guard let user = byId[posts[index].authorId] else { continue }
            if posts[index].authorName == "未知用户" || posts[index].authorName.isEmpty, !user.name.isEmpty {
                posts[index].authorName = user.name
            }
            if posts[index].authorPortrait.isEmpty {
                posts[index].authorPortrait = user.portrait
            }
        }
    }

    // MARK: - 帖子列表（已验证通过）

    func fetchThreads(forumName: String, page: Int) async throws -> ForumThreads {
        let cacheKey = "\(forumName)#\(page)"
        if let (at, cached) = threadsCache[cacheKey], Date().timeIntervalSince(at) < 60 {
            return cached
        }
        let data = try await request(path: "/c/f/frs/page", params: ["kw": forumName, "pn": String(page)], method: "GET")
        let response = try decode(data, as: FrsResponse.self)
        var threads = response.threadList ?? []
        applyUsers(response.userList, to: &threads)
        let result = ForumThreads(
            forumId: response.forum?.id ?? "",
            forumName: response.forum?.name.isEmpty == false ? (response.forum?.name ?? forumName) : forumName,
            threads: threads)
        threadsCache[cacheKey] = (Date(), result)
        return result
    }

    // MARK: - 帖子详情（客户端接口未验证通过：匿名和登录后均报删帖）
    // 主路径：先试客户端接口，失败即返回空并让 UI 自动切网页版详情（官方页面，已验证能看到楼层）。
    // 这里不把客户端报错伪装成帖子已删，调用方按空结果处理。

    func fetchPosts(tid: String, page: Int) async throws -> [TiebaPost] {
        guard !tid.isEmpty else {
            throw TiebaError.server("帖子 id 为空，请回到列表重新打开这条帖子")
        }
        let cacheKey = "\(tid)#\(page)"
        if let (at, cached) = postsCache[cacheKey], Date().timeIntervalSince(at) < 60 {
            return cached
        }
        let variants: [[String: String]] = [
            ["tid": tid, "pn": String(page)],
            ["tid": tid, "pn": String(page), "rn": "30", "with_floor": "1"],
            ["tid": tid, "pn": String(page), "kz": "1"],
        ]
        var lastError: Error = TiebaError.invalidResponse
        for params in variants {
            do {
                let data = try await request(path: "/c/f/pb/page", params: params, method: "GET")
                let response = try decode(data, as: PbResponse.self)
                var posts = response.postList ?? []
                applyUsers(response.userList, to: &posts)
                if !posts.isEmpty {
                    postsCache[cacheKey] = (Date(), posts)
                    return posts
                }
            } catch {
                lastError = error
            }
        }
        if page == 1 {
            do {
                let data = try await request(path: "/c/f/pb/page", params: ["tid": tid, "pn": "1", "rn": "30", "with_floor": "1"], method: "POST")
                let response = try decode(data, as: PbResponse.self)
                if let posts = response.postList, !posts.isEmpty {
                    postsCache[cacheKey] = (Date(), posts)
                    return posts
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func fetchSubPosts(tid: String, pid: String, page: Int) async throws -> [TiebaSubPost] {
        let data = try await request(path: "/c/f/pb/floor", params: ["tid": tid, "pid": pid, "pn": String(page)], method: "GET")
        let response = try decode(data, as: FloorResponse.self)
        var subs = response.subpostList ?? []
        if let users = response.userList, !users.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, AuthorInfo)? in
                guard !user.id.isEmpty else { return nil }
                return (user.id, user)
            })
            for index in subs.indices {
                if (subs[index].authorName == "未知用户" || subs[index].authorName.isEmpty),
                   let user = byId[subs[index].authorId], !user.name.isEmpty {
                    subs[index].authorName = user.name
                }
            }
        }
        return subs
    }

    // MARK: - 关注的吧（客户端接口匿名返回空，登录后未验证通过；网页版导入为兜底）

    func fetchFollowedForums() async throws -> [String] {
        guard KeychainStore.isLoggedIn else { return [] }
        for path in ["/c/f/forum/like", "/c/f/user/like", "/c/f/forum/fav"] {
            do {
                let data = try await request(path: path, params: ["pn": "1"], method: "GET")
                let names = forumNames(in: data)
                if !names.isEmpty { return names }
            } catch {
                continue
            }
        }
        if let webNames = try? await fetchFollowedForumsFromWeb(), !webNames.isEmpty {
            return webNames
        }
        return []
    }

    private func fetchFollowedForumsFromWeb() async throws -> [String] {
        for urlString in ["https://tieba.baidu.com/i/i/my_forum", "https://tieba.baidu.com/f/like/mylike"] {
            guard let url = URL(string: urlString) else { continue }
            var urlRequest = URLRequest(url: url)
            urlRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            if let cookie = cookieHeader {
                urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            guard let (data, _) = try? await URLSession.shared.data(for: urlRequest),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let raw = matches(in: html, pattern: "/f\\?kw=([^\"&<>]+)")
            var seen = Set<String>()
            var result: [String] = []
            for item in raw {
                let name = item.removingPercentEncoding?.replacingOccurrences(of: "+", with: " ") ?? item
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !seen.contains(trimmed) {
                    seen.insert(trimmed)
                    result.append(trimmed)
                }
            }
            if !result.isEmpty { return result }
        }
        return []
    }

    private func forumNames(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        collectForumNames(from: object, into: &result, seen: &seen)
        return result
    }

    private func collectForumNames(from object: Any, into result: inout [String], seen: inout Set<String>) {
        if let dict = object as? [String: Any] {
            if let fname = dict["fname"] as? String, !fname.isEmpty, !seen.contains(fname) {
                seen.insert(fname)
                result.append(fname)
            } else if let forumName = dict["forum_name"] as? String, !forumName.isEmpty, !seen.contains(forumName) {
                seen.insert(forumName)
                result.append(forumName)
            }
            for value in dict.values {
                collectForumNames(from: value, into: &result, seen: &seen)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectForumNames(from: value, into: &result, seen: &seen)
            }
        }
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }

    // MARK: - 发帖/回复（需要登录态，未在真机验证通过；提交间隔 5 秒）

    private func checkSubmitInterval() throws {
        if let last = lastSubmitAt, Date().timeIntervalSince(last) < 5 {
            throw TiebaError.server("提交太快了，请等几秒再提交")
        }
        lastSubmitAt = Date()
    }

    func fetchTBS() async throws -> String {
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard let url = URL(string: "https://tieba.baidu.com/dc/common/tbs") else {
            throw TiebaError.invalidResponse
        }
        var urlRequest = URLRequest(url: url)
        if let cookie = cookieHeader {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TiebaError.server("贴吧返回 HTTP \(http.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tbs = object["tbs"] as? String, !tbs.isEmpty else {
            throw TiebaError.missingTBS
        }
        return tbs
    }

    func addThread(forumId: String, forumName: String, title: String, content: String) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再发帖") }
        writeInFlight = true
        defer { writeInFlight = false }
        let tbs = try await fetchTBS()
        _ = try await request(path: "/c/c/thread/add", params: ["fid": forumId, "kw": forumName, "title": title, "content": content, "tbs": tbs], method: "POST")
    }

    func addPost(forumId: String, forumName: String, tid: String, content: String) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再回复") }
        writeInFlight = true
        defer { writeInFlight = false }
        let tbs = try await fetchTBS()
        _ = try await request(path: "/c/c/post/add", params: ["fid": forumId, "kw": forumName, "tid": tid, "content": content, "tbs": tbs], method: "POST")
    }

    func addComment(forumId: String, forumName: String, tid: String, pid: String, content: String) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再回复") }
        writeInFlight = true
        defer { writeInFlight = false }
        let tbs = try await fetchTBS()
        _ = try await request(path: "/c/c/comment/add", params: ["fid": forumId, "kw": forumName, "tid": tid, "pid": pid, "content": content, "tbs": tbs], method: "POST")
    }
}
