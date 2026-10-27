import CryptoKit
import Foundation

// MARK: - 贴吧客户端：全部请求直连贴吧，不经过任何自有服务器

@MainActor
final class TiebaClient {
    static let shared = TiebaClient()
    private init() {}

    private let baseURL = "https://c.tieba.baidu.com"
    private let clientVersion = "12.51.7.1"
    private var writeInFlight = false

    // 签名：参数按 key 排序拼 key=value（无分隔符），后加 "tiebaclient!!!"，MD5 小写 hex。
    static func sign(_ params: [String: String]) -> String {
        let base = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
            + "tiebaclient!!!"
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

    // 按开发文档红线：不伪造设备指纹。上一版加的本机 UUID cuid 已删除，
    // 只发接口本身要求的 _client_type / _client_version / sign，不再多带设备标识。
    // 标准、合理的 User-Agent，不伪装成官方客户端以外的设备。
    private func signedParams(_ params: [String: String]) -> [String: String] {
        var signed = params
        signed["_client_type"] = "2"
        signed["_client_version"] = clientVersion
        signed["sign"] = Self.sign(signed)
        return signed
    }

    // 提交间隔：发帖/回复两次提交至少间隔 5 秒，连续点击不会连发请求。
    // 缓存：帖子列表、详情按页短时缓存 60 秒，减少重复请求。
    private var lastSubmitAt: Date?
    private var threadsCache: [String: (Date, ForumThreads)] = [:]
    private var postsCache: [String: (Date, [TiebaPost])] = [:]

    private func checkSubmitInterval() throws {
        if let last = lastSubmitAt, Date().timeIntervalSince(last) < 5 {
            throw TiebaError.server("提交太快了，请等几秒再提交")
        }
        lastSubmitAt = Date()
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
            urlRequest.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
            // 先看服务端有没有给 error_msg，有就原样抛，没就报 HTTP 状态。
            do {
                try checkError(in: data)
            } catch {
                throw error
            }
            throw TiebaError.server("贴吧返回 HTTP \(http.statusCode)")
        }
        try checkError(in: data)
        return data
    }

    // error_code 非 0 时抛错：先把服务端常见错误映射成清晰中文提示，
    // 再把原错附在后面，不吞错。验证码一律交给用户手动处理，不自动识别或绕过。
    @discardableResult
    private func checkError(in data: Data) throws -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        if let code = jsonInt(object["error_code"]), code != 0 {
            let message = jsonString(object["error_msg"])
            throw TiebaError.server(Self.friendlyError(code: code, message: message))
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
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TiebaError.invalidResponse
        }
    }

    // MARK: - 读取（未登录也可读，只读接口不强制带 BDUSS）

    // 帖子列表：GET c/f/frs/page（kw, pn）
    func fetchThreads(forumName: String, page: Int) async throws -> ForumThreads {
        let cacheKey = "\(forumName)#\(page)"
        if let (at, cached) = threadsCache[cacheKey], Date().timeIntervalSince(at) < 60 {
            return cached
        }
        let data = try await request(
            path: "/c/f/frs/page", params: ["kw": forumName, "pn": String(page)], method: "GET")
        let response = try decode(data, as: FrsResponse.self)
        let resolvedForumName = response.forum?.name ?? ""
        var threads = response.threadList ?? []
        // 作者可能不在 thread 里、而在单独的 user_list 里按 author_id 映射。
        // 用户名和头像一起映射：头像缺了，列表就只能显示首字。
        if let users = response.userList, !users.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, AuthorInfo)? in
                guard !user.id.isEmpty else { return nil }
                return (user.id, user)
            })
            for index in threads.indices {
                guard let user = byId[threads[index].authorId] else { continue }
                if threads[index].authorName == "未知用户" || threads[index].authorName.isEmpty,
                   !user.name.isEmpty {
                    threads[index].authorName = user.name
                }
                if threads[index].authorPortrait.isEmpty {
                    threads[index].authorPortrait = user.portrait
                }
            }
        }
        let result = ForumThreads(
            forumId: response.forum?.id ?? "",
            forumName: resolvedForumName.isEmpty ? forumName : resolvedForumName,
            threads: threads)
        threadsCache[cacheKey] = (Date(), result)
        return result
    }

    // 楼层列表：GET c/f/pb/page（tid, pn）。
    // 截图里详情页报“帖子可能已被删除”：先排除 tid 为空，再按参数组合依次重试
    // （只带 tid/pn → 加 rn/with_floor → 加 kz），某组成功即返回，不再把第一组的
    // 服务端报错直接当成帖子已删。全部失败才抛最后一次的原错。
    func fetchPosts(tid: String, page: Int) async throws -> [TiebaPost] {
        guard !tid.isEmpty else {
            throw TiebaError.server("帖子 id 为空（tid 为空），请回到列表重新打开这条帖子")
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
                if let users = response.userList, !users.isEmpty {
                    let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, AuthorInfo)? in
                        guard !user.id.isEmpty else { return nil }
                        return (user.id, user)
                    })
                    for index in posts.indices {
                        guard let user = byId[posts[index].authorId] else { continue }
                        if posts[index].authorName == "未知用户" || posts[index].authorName.isEmpty,
                           !user.name.isEmpty {
                            posts[index].authorName = user.name
                        }
                        if posts[index].authorPortrait.isEmpty {
                            posts[index].authorPortrait = user.portrait
                        }
                    }
                }
                postsCache[cacheKey] = (Date(), posts)
                return posts
            } catch {
                lastError = error
            }
        }
        // GET 全部失败时再试一次 POST：部分客户端接口只接受 POST 形式，
        // 参数与 GET 的第二组相同（rn + with_floor）。
        if page == 1 {
            do {
                let data = try await request(
                    path: "/c/f/pb/page",
                    params: ["tid": tid, "pn": "1", "rn": "30", "with_floor": "1"],
                    method: "POST")
                let response = try decode(data, as: PbResponse.self)
                if let posts = response.postList, !posts.isEmpty {
                    postsCache[cacheKey] = (Date(), posts)
                    return posts
                }
            } catch {
                lastError = error
            }
        }
        // 客户端接口全部报删帖时，改走网页版帖子页：只取楼层文字和作者名，
        // 至少把原帖的回复显示出来。网页也拿不到时，才抛客户端接口的原错。
        if let webPosts = try? await fetchPostsFromWeb(tid: tid, page: page), !webPosts.isEmpty {
            postsCache[cacheKey] = (Date(), webPosts)
            return webPosts
        }
        throw lastError
    }

    // 网页版兜底：GET tieba.baidu.com/p/<tid>，从 HTML 里按顺序取
    // p_author_name（作者）和 d_post_content（楼层文字），配对成楼层。
    // 只做文字，图片暂不解析；页数只支持第 1 页，翻页仍走客户端接口。
    private func fetchPostsFromWeb(tid: String, page: Int) async throws -> [TiebaPost] {
        guard page == 1, let url = URL(string: "https://tieba.baidu.com/p/\(tid)") else {
            return []
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        if let cookie = cookieHeader {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        guard let html = String(data: data, encoding: .utf8), !html.contains("安全验证") else {
            return []
        }
        let authors = matches(in: html, pattern: "p_author_name[^>]*>([^<]+)<")
        let contents = matches(in: html, pattern: "d_post_content[^>]*>(.*?)</div>")
        var posts: [TiebaPost] = []
        for index in contents.indices {
            let text = stripHTML(contents[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let author = index < authors.count ? authors[index].trimmingCharacters(in: .whitespacesAndNewlines) : "未知用户"
            posts.append(TiebaPost(
                pid: "\(tid)-\(index + 1)", floor: index + 1,
                authorName: author.isEmpty ? "未知用户" : author, authorId: "",
                time: 0, content: [ContentFragment(type: 0, text: text, originSrc: "")],
                subPostCount: 0))
        }
        return posts
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }

    private func stripHTML(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    // 楼中楼分页：GET c/f/pb/floor（tid, pid, pn）
    func fetchSubPosts(tid: String, pid: String, page: Int) async throws -> [TiebaSubPost] {
        let data = try await request(
            path: "/c/f/pb/floor",
            params: ["tid": tid, "pid": pid, "pn": String(page)], method: "GET")
        let response = try decode(data, as: FloorResponse.self)
        var subs = response.subpostList ?? []
        if let users = response.userList, !users.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, String)? in
                guard !user.id.isEmpty, !user.name.isEmpty else { return nil }
                return (user.id, user.name)
            })
            for index in subs.indices {
                if (subs[index].authorName == "未知用户" || subs[index].authorName.isEmpty),
                   let name = byId[subs[index].authorId] {
                    subs[index].authorName = name
                }
            }
        }
        return subs
    }

    // 关注的吧：依次试几个客户端“关注”接口，第一个返回非空吧名列表的胜出。
    // 吧名从返回 JSON 里递归找：forum_list / like_forum 等数组里含 fname 的字典。
    // 全部失败或为空时返回空数组，界面退回本地保存的吧，不阻塞首页。
    func fetchFollowedForums() async throws -> [String] {
        guard KeychainStore.isLoggedIn else { return [] }
        let paths = ["/c/f/forum/like", "/c/f/user/like", "/c/f/forum/fav"]
        for path in paths {
            do {
                let data = try await request(path: path, params: ["pn": "1"], method: "GET")
                let names = forumNames(in: data)
                if !names.isEmpty { return names }
            } catch {
                continue
            }
        }
        // 客户端接口返回空时，改走网页版“我的吧”页面：吧链接形如 /f?kw=吧名，
        // 从链接里直接取吧名，不依赖客户端接口的字段名。
        if let webNames = try? await fetchFollowedForumsFromWeb(), !webNames.isEmpty {
            return webNames
        }
        return []
    }

    private func fetchFollowedForumsFromWeb() async throws -> [String] {
        let urls = [
            "https://tieba.baidu.com/i/i/my_forum",
            "https://tieba.baidu.com/f/like/mylike",
        ]
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var urlRequest = URLRequest(url: url)
            urlRequest.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            if let cookie = cookieHeader {
                urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            guard let (data, _) = try? await URLSession.shared.data(for: urlRequest),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let raw = matches(in: html, pattern: "/f\\?kw=([^\"&<>]+)")
            var seen = Set<String>()
            var result: [String] = []
            for item in raw {
                let name = item.removingPercentEncoding?.replacingOccurrences(of: "+", with: " ")
                    ?? item
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

    // MARK: - 发帖（写操作串行：提交中再次提交直接报错，不并发）

    // 发帖凭证：GET tieba.baidu.com/dc/common/tbs（带 BDUSS Cookie）
    func fetchTBS() async throws -> String {
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard let url = URL(string: "https://tieba.baidu.com/dc/common/tbs") else {
            throw TiebaError.invalidResponse
        }
        var urlRequest = URLRequest(url: url)
        if let cookie = cookieHeader {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TiebaError.network(error.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tbs = object["tbs"] as? String, !tbs.isEmpty else {
            throw TiebaError.missingTBS
        }
        return tbs
    }

    // 发主题：POST c/c/thread/add（fid, kw, title, content, tbs）
    func addThread(forumId: String, forumName: String, title: String, content: String) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再发帖") }
        writeInFlight = true
        defer { writeInFlight = false }
        let tbs = try await fetchTBS()
        _ = try await request(
            path: "/c/c/thread/add",
            params: ["fid": forumId, "kw": forumName, "title": title, "content": content, "tbs": tbs],
            method: "POST")
    }

    // 回帖：POST c/c/post/add（fid, kw, tid, content, tbs）
    func addPost(forumId: String, forumName: String, tid: String, content: String) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再回复") }
        writeInFlight = true
        defer { writeInFlight = false }
        let tbs = try await fetchTBS()
        _ = try await request(
            path: "/c/c/post/add",
            params: ["fid": forumId, "kw": forumName, "tid": tid, "content": content, "tbs": tbs],
            method: "POST")
    }

    // 楼中楼：POST c/c/comment/add（fid, kw, tid, pid, content, tbs）
    func addComment(forumId: String, forumName: String, tid: String, pid: String, content: String) async throws {
        guard !writeInFlight else { throw TiebaError.alreadySubmitting }
        try checkSubmitInterval()
        guard KeychainStore.isLoggedIn else { throw TiebaError.notLoggedIn }
        guard !forumId.isEmpty else { throw TiebaError.server("缺少吧 id，请先打开该吧再回复") }
        writeInFlight = true
        defer { writeInFlight = false }
        let tbs = try await fetchTBS()
        _ = try await request(
            path: "/c/c/comment/add",
            params: ["fid": forumId, "kw": forumName, "tid": tid, "pid": pid, "content": content, "tbs": tbs],
            method: "POST")
    }
}
