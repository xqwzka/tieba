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

    // App 自生成的安装标识（随机 UUID，首次启动生成后存本地复用），不是硬件信息。
    // protobuf 发帖的 URL 参数和 common 体里都要带，否则服务端报未登录。
    private var clientId: String {
        let key = "tiebaClientId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
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
        // TiebaLite 的做法：BDUSS/STOKEN 是请求参数，不是只放 Cookie；
        // 只放 Cookie 时需要登录态的客户端接口（如关注的吧）认不出登录用户。
        if let bduss = KeychainStore.bduss, !bduss.isEmpty {
            signed["BDUSS"] = bduss
        }
        if let stoken = KeychainStore.stoken, !stoken.isEmpty {
            signed["STOKEN"] = stoken
        }
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
        // 客户端接口按 TiebaLite 的做法带官方客户端 UA（版本与 _client_version 参数一致），
        // 避免服务端把请求当成网页请求处理（例如重定向到 http 页面）。
        urlRequest.setValue("bdtb for Android \(clientVersion)", forHTTPHeaderField: "User-Agent")
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

    func fetchThreads(forumName: String, page: Int, force: Bool = false) async throws -> ForumThreads {
        let cacheKey = "\(forumName)#\(page)"
        if !force, let (at, cached) = threadsCache[cacheKey], Date().timeIntervalSince(at) < 60 {
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

    // MARK: - 帖子详情（已验证通过，2026-10-27 只读实测）
    // 根因：之前一直发 tid 参数，服务端不认，报删帖。TiebaLite 的写法是 kz=帖子 id：
    // 匿名 GET kz=11140407932 已实测返回 error_code 0、post_list 15 条（1~15 楼），
    // 首楼作者经 user_list 映射为“萌酱”，与网页版一致。主路径仍是客户端接口，
    // 失败才由 UI 切网页版详情，不把报错伪装成帖子已删。

    func fetchPosts(tid: String, page: Int, force: Bool = false) async throws -> [TiebaPost] {
        guard !tid.isEmpty else {
            throw TiebaError.server("帖子 id 为空，请回到列表重新打开这条帖子")
        }
        let cacheKey = "\(tid)#\(page)"
        if !force, let (at, cached) = postsCache[cacheKey], Date().timeIntervalSince(at) < 60 {
            return cached
        }
        // 实测结论：rn=30 时服务端翻页不生效，pn=2、pn=3 都返回从 1 楼起的全部楼层，
        // 所以“加载更多”会把已看过的楼层再贴一遍；rn=15 时 pn 正常工作
        //（第 1 页 1~15 楼，第 2 页 16~19 楼），和 TiebaLite 的 rn=15 一致。必须用 15。
        let attempts: [(method: String, params: [String: String])] = [
            ("GET", ["kz": tid, "pn": String(page), "rn": "15", "with_floor": "1"]),
            ("POST", ["kz": tid, "pn": String(page), "rn": "15", "with_floor": "1",
                      "st_type": "tb_frslist", "back": "0", "floor_rn": "3", "mark": "0", "lz": "0"]),
        ]
        var lastError: Error = TiebaError.invalidResponse
        for attempt in attempts {
            do {
                let data = try await request(path: "/c/f/pb/page", params: attempt.params, method: attempt.method)
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
        throw lastError
    }

    func fetchSubPosts(tid: String, pid: String, page: Int) async throws -> [TiebaSubPost] {
        // 楼中楼同理：TiebaLite 用 kz=帖子 id + pid，POST 表单；之前 tid + GET 未验证通过。
        let data = try await request(path: "/c/f/pb/floor", params: ["kz": tid, "pid": pid, "pn": String(page), "rn": "20"], method: "POST")
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
        // TiebaLite 的写法：POST /c/f/forum/like，page_no/page_size，不是 GET pn；
        // 返回结构是 forum_list["non-gconforum"][].name（另有 common_forum_list 同结构）。
        // 之前 GET pn=1 + 只认 fname/forum_name，所以登录后也一直是空。
        do {
            let data = try await request(path: "/c/f/forum/like", params: ["page_no": "1", "page_size": "50"], method: "POST")
            let names = followedForumNames(in: data)
            if !names.isEmpty { return names }
        } catch {
            // 落到下面的兜底
        }
        for path in ["/c/f/user/like", "/c/f/forum/fav"] {
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

    private func followedForumNames(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for listKey in ["forum_list", "common_forum_list"] {
            guard let list = object[listKey] as? [String: Any] else { continue }
            for group in list.values {
                guard let forums = group as? [[String: Any]] else { continue }
                for forum in forums {
                    if let name = forum["name"] as? String, !name.isEmpty, !seen.contains(name) {
                        seen.insert(name)
                        result.append(name)
                    }
                }
            }
        }
        if result.isEmpty {
            result = forumNames(in: data)
        }
        return result
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
        // tbs 是回复和发帖的公共前置步骤：它挂了，两边一起挂。
        // 之前这里 https 请求失败时把系统错误原样抛出去，界面上就是截图里那句
        // 没有“网络错误：”前缀的 ATS 原文；现在 https 失败改走 http 再试一次
        //（已给 tieba.baidu.com 加明文例外），两次都失败才报带步骤名的错。
        var lastError: Error?
        for scheme in ["https", "http"] {
            guard let url = URL(string: "\(scheme)://tieba.baidu.com/dc/common/tbs") else { continue }
            var urlRequest = URLRequest(url: url)
            urlRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            if let cookie = cookieHeader {
                urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = TiebaError.server("贴吧返回 HTTP \(http.statusCode)")
                    continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tbs = object["tbs"] as? String, !tbs.isEmpty else {
                    // https 返回的可能是登录页之类的非 tbs 内容，也留给 http 再试一次，
                    // 两次都拿不到才报凭证失败。
                    lastError = TiebaError.missingTBS
                    continue
                }
                return tbs
            } catch let error as TiebaError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw TiebaError.network("获取发帖凭证(tbs)失败：\(lastError?.localizedDescription ?? "未知错误")")
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
        // 发新帖成功后清掉该吧的列表缓存，否则列表 60 秒内还是旧数据。
        threadsCache.keys.filter { $0.hasPrefix("\(forumName)#") }.forEach { threadsCache.removeValue(forKey: $0) }
    }

    // 发帖/回复走 protobuf 接口（TiebaLite 现行做法）：
    // JSON 表单接口服务端收了也不落库，是之前“无报错但发不出去”的根因。
    // 成功后清掉该帖的详情缓存，否则 60 秒缓存会让刚发的楼层在自己这边也看不到。
    private func postViaProtobuf(forumId: String, forumName: String, tid: String, content: String, postId: String?, replyUid: String?) async throws {
        guard let bduss = KeychainStore.bduss, !bduss.isEmpty else { throw TiebaError.notLoggedIn }
        let tbs = try await fetchTBS()
        let protobuf = TiebaProtobuf.addPostRequest(
            bduss: bduss, stoken: KeychainStore.stoken, tbs: tbs, clientId: clientId,
            fid: forumId, kw: forumName, tid: tid, content: content,
            postId: postId, replyUid: replyUid)
        let (body, contentType) = TiebaProtobuf.multipartBody(stoken: KeychainStore.stoken, protobuf: protobuf)
        // 关键修正：TiebaLite 的 protobuf 实例经默认拦截器在 URL 上带 BDUSS/STOKEN/
        // _client_type/_timestamp；上一版只把 BDUSS 放进 protobuf 体和 Cookie，
        // 服务端不认登录态，回复报“用户未登录或登录失败”。这些是会话参数，不是设备指纹。
        var components = URLComponents(string: "https://tiebac.baidu.com/c/c/post/add")!
        var queryItems = [
            URLQueryItem(name: "cmd", value: "309731"),
            URLQueryItem(name: "format", value: "protobuf"),
            URLQueryItem(name: "_client_version", value: "12.35.1.0"),
            URLQueryItem(name: "BDUSS", value: bduss),
            URLQueryItem(name: "_client_id", value: clientId),
            URLQueryItem(name: "_client_type", value: "2"),
            URLQueryItem(name: "_timestamp", value: String(Int64(Date().timeIntervalSince1970 * 1000))),
        ]
        if let stoken = KeychainStore.stoken, !stoken.isEmpty {
            queryItems.append(URLQueryItem(name: "STOKEN", value: stoken))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw TiebaError.invalidResponse
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("tieba/12.35.1.0", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("protobuf", forHTTPHeaderField: "X-BD-DATA-TYPE")
        urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let cookie = cookieHeader {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        urlRequest.httpBody = body
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TiebaError.network("发帖提交失败：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TiebaError.network("发帖提交失败：贴吧返回 HTTP \(http.statusCode)")
        }
        guard let (code, message) = TiebaProtobuf.parseAddPostError(data) else {
            // 响应不是 protobuf：可能是风控页/登录页，必须报错，不能再当成功。
            throw TiebaError.server("发帖失败：服务端返回无法解析，请去官方 App 确认登录态后再试")
        }
        guard code == 0 else {
            throw TiebaError.server(message.isEmpty ? "发帖失败（错误码 \(code)）" : message)
        }
        postsCache.keys.filter { $0.hasPrefix("\(tid)#") }.forEach { postsCache.removeValue(forKey: $0) }
    }

    func addPost(forumId: String, forumName: String, tid: String, content: String) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再回复") }
        writeInFlight = true
        defer { writeInFlight = false }
        try await postViaProtobuf(forumId: forumId, forumName: forumName, tid: tid, content: content, postId: nil, replyUid: nil)
    }

    func addComment(forumId: String, forumName: String, tid: String, pid: String, content: String, replyUid: String? = nil) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再回复") }
        writeInFlight = true
        defer { writeInFlight = false }
        try await postViaProtobuf(forumId: forumId, forumName: forumName, tid: tid, content: content, postId: pid, replyUid: replyUid)
    }
}
