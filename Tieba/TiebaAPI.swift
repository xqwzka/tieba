import CryptoKit
import Foundation

// MARK: - 错误：服务端 error_msg 原样透传，不吞错

enum TiebaError: LocalizedError {
    case server(String)
    case network(String)
    case invalidResponse
    case notLoggedIn
    case missingTBS
    case alreadySubmitting

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .network(let message): return "网络请求失败：\(message)"
        case .invalidResponse: return "贴吧返回的数据无法解析"
        case .notLoggedIn: return "请先登录"
        case .missingTBS: return "获取发帖凭证（tbs）失败，请重新登录"
        case .alreadySubmitting: return "正在提交，请稍候"
        }
    }
}

// MARK: - 防御式解析：字段缺失、数字/字符串混用都不崩溃

extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String {
        if let text = try? decode(String.self, forKey: key) {
            return text
        }
        if let number = try? decode(Int.self, forKey: key) {
            return String(number)
        }
        if let number = try? decode(Double.self, forKey: key) {
            return String(Int(number))
        }
        return ""
    }

    func flexibleInt(forKey key: Key) -> Int {
        if let number = try? decode(Int.self, forKey: key) {
            return number
        }
        if let text = try? decode(String.self, forKey: key), let number = Int(text) {
            return number
        }
        if let number = try? decode(Double.self, forKey: key) {
            return Int(number)
        }
        return 0
    }
}

struct ForumInfo: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id)
        name = container.flexibleString(forKey: .name)
    }
}

struct AuthorInfo: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id, name, userName = "user_name", userId = "user_id", uid, nickname, showNickname = "show_nickname", nameShow = "name_show"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = container.flexibleString(forKey: .id)
        let userId = container.flexibleString(forKey: .userId)
        let uid = container.flexibleString(forKey: .uid)
        self.id = !id.isEmpty ? id : (!userId.isEmpty ? userId : uid)
        // 实测：frs 的 user_list 里用户名在 name_show（name 也可能同值），
        // 而 thread 条目里的 author 对象只有 show_icon_list、没有用户名，
        // 所以用户名必须靠 user_list 按 author_id 映射，name_show 不能漏。
        let name = container.flexibleString(forKey: .name)
        let nameShow = container.flexibleString(forKey: .nameShow)
        let userName = container.flexibleString(forKey: .userName)
        let nickname = container.flexibleString(forKey: .nickname)
        let showNickname = container.flexibleString(forKey: .showNickname)
        self.name = [name, nameShow, userName, nickname, showNickname].first { !$0.isEmpty } ?? ""
    }
}

// 帖子列表项（c/f/frs/page 的 thread_list）
// createTime 和 lastTime 分开存：排序“新帖”用 createTime，“回复时间”用 lastTime，
// “热门”用 replyNum。两者缺失时互相兜底，界面显示不为空。
struct TiebaThread: Identifiable, Decodable {
    var id: String { tid }
    let tid: String
    let title: String
    var authorName: String
    var authorId: String
    let replyNum: Int
    let viewNum: Int
    let createTime: Int
    let lastTime: Int
    let threadForumName: String

    enum CodingKeys: String, CodingKey {
        case tid, title, author
        case replyNum = "reply_num"
        case viewNum = "view_num"
        case createTime = "create_time"
        case lastTime = "last_time"
        case fname
        case forumName = "forum_name"
        case authorId = "author_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tid = container.flexibleString(forKey: .tid)
        title = container.flexibleString(forKey: .title)
        var authorName = "未知用户"
        var authorId = container.flexibleString(forKey: .authorId)
        if let author = try? container.decode(AuthorInfo.self, forKey: .author) {
            if !author.name.isEmpty { authorName = author.name }
            if !author.id.isEmpty { authorId = author.id }
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        self.authorId = authorId
        replyNum = container.flexibleInt(forKey: .replyNum)
        viewNum = container.flexibleInt(forKey: .viewNum)
        let createTime = container.flexibleInt(forKey: .createTime)
        let lastTime = container.flexibleInt(forKey: .lastTime)
        self.createTime = createTime != 0 ? createTime : lastTime
        self.lastTime = lastTime != 0 ? lastTime : createTime
        let fname = container.flexibleString(forKey: .fname)
        let forumName = container.flexibleString(forKey: .forumName)
        self.threadForumName = !fname.isEmpty ? fname : forumName
    }
}

// 帖子排序：热门 = 回复数降序（同回复数按最后回复时间），
// 回复时间 = 最后回复时间降序，新帖 = 发帖时间降序。
enum ThreadSort: String, CaseIterable {
    case hot = "热门"
    case replyTime = "回复时间"
    case newest = "新帖"

    func sort(_ threads: [TiebaThread]) -> [TiebaThread] {
        switch self {
        case .hot:
            return threads.sorted {
                if $0.replyNum != $1.replyNum { return $0.replyNum > $1.replyNum }
                return $0.lastTime > $1.lastTime
            }
        case .replyTime:
            return threads.sorted { $0.lastTime > $1.lastTime }
        case .newest:
            return threads.sorted { $0.createTime > $1.createTime }
        }
    }
}

// 楼层内容片段：type 0=文字，3=图片（origin_src）
struct ContentFragment: Decodable {
    let type: Int
    let text: String
    let originSrc: String

    enum CodingKeys: String, CodingKey {
        case type, text
        case originSrc = "origin_src"
    }

    init(type: Int, text: String, originSrc: String) {
        self.type = type
        self.text = text
        self.originSrc = originSrc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.flexibleInt(forKey: .type)
        text = container.flexibleString(forKey: .text)
        originSrc = container.flexibleString(forKey: .originSrc)
    }
}

// 楼层（c/f/pb/page 的 post_list）
struct TiebaPost: Identifiable, Decodable {
    var id: String { pid }
    let pid: String
    let floor: Int
    var authorName: String
    var authorId: String
    let time: Int
    let content: [ContentFragment]
    let subPostCount: Int

    var text: String {
        content.filter { $0.type == 0 }.map { $0.text }.joined()
    }
    var imageURLs: [String] {
        content.filter { $0.type == 3 }.map { $0.originSrc }.filter { !$0.isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case pid, floor, author, time, content
        case subPostCount = "sub_post_number"
        case authorId = "author_id"
    }

    init(pid: String, floor: Int, authorName: String, authorId: String, time: Int, content: [ContentFragment], subPostCount: Int) {
        self.pid = pid
        self.floor = floor
        self.authorName = authorName
        self.authorId = authorId
        self.time = time
        self.content = content
        self.subPostCount = subPostCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = container.flexibleString(forKey: .pid)
        floor = container.flexibleInt(forKey: .floor)
        var authorName = "未知用户"
        var authorId = container.flexibleString(forKey: .authorId)
        if let author = try? container.decode(AuthorInfo.self, forKey: .author) {
            if !author.name.isEmpty { authorName = author.name }
            if !author.id.isEmpty { authorId = author.id }
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        self.authorId = authorId
        time = container.flexibleInt(forKey: .time)
        // content 可能是片段数组，也可能是纯字符串，两种都接。
        if let fragments = try? container.decode([ContentFragment].self, forKey: .content) {
            content = fragments
        } else if let text = try? container.decode(String.self, forKey: .content), !text.isEmpty {
            content = [ContentFragment(type: 0, text: text, originSrc: "")]
        } else {
            content = []
        }
        subPostCount = container.flexibleInt(forKey: .subPostCount)
    }
}

// 楼中楼（c/f/pb/floor 的 subpost_list，content 多为纯字符串）
struct TiebaSubPost: Identifiable, Decodable {
    var id: String { pid }
    let pid: String
    var authorName: String
    var authorId: String
    let time: Int
    let contentText: String

    enum CodingKeys: String, CodingKey {
        case pid, author, time, content
        case authorId = "author_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = container.flexibleString(forKey: .pid)
        var authorName = "未知用户"
        var authorId = container.flexibleString(forKey: .authorId)
        if let author = try? container.decode(AuthorInfo.self, forKey: .author) {
            if !author.name.isEmpty { authorName = author.name }
            if !author.id.isEmpty { authorId = author.id }
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        self.authorId = authorId
        time = container.flexibleInt(forKey: .time)
        if let text = try? container.decode(String.self, forKey: .content) {
            contentText = text
        } else if let fragments = try? container.decode([ContentFragment].self, forKey: .content) {
            contentText = fragments.map { $0.text }.joined()
        } else {
            contentText = ""
        }
    }
}

struct FrsResponse: Decodable {
    let forum: ForumInfo?
    let threadList: [TiebaThread]?
    let userList: [AuthorInfo]?

    enum CodingKeys: String, CodingKey {
        case forum
        case threadList = "thread_list"
        case userList = "user_list"
    }
}

struct PbResponse: Decodable {
    let postList: [TiebaPost]?
    let userList: [AuthorInfo]?

    enum CodingKeys: String, CodingKey {
        case postList = "post_list"
        case userList = "user_list"
    }
}

struct FloorResponse: Decodable {
    let subpostList: [TiebaSubPost]?
    let userList: [AuthorInfo]?

    enum CodingKeys: String, CodingKey {
        case subpostList = "subpost_list"
        case userList = "user_list"
    }
}

struct ForumThreads {
    let forumId: String
    let forumName: String
    let threads: [TiebaThread]
}

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

    // 设备标识：本机生成一次的 UUID，只用来让服务端认出是同一台客户端，
    // 不含任何账号信息，也不发给除贴吧外的任何地方。
    private var deviceId: String {
        let key = "tiebaDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private func signedParams(_ params: [String: String]) -> [String: String] {
        var signed = params
        signed["_client_type"] = "2"
        signed["_client_version"] = clientVersion
        signed["cuid"] = deviceId
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

    // error_code 非 0 时抛错，error_msg 原样透传。
    @discardableResult
    private func checkError(in data: Data) throws -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        if let code = jsonInt(object["error_code"]), code != 0 {
            let message = jsonString(object["error_msg"])
            throw TiebaError.server(message.isEmpty ? "贴吧返回错误（\(code)）" : message)
        }
        return true
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
        let data = try await request(
            path: "/c/f/frs/page", params: ["kw": forumName, "pn": String(page)], method: "GET")
        let response = try decode(data, as: FrsResponse.self)
        let resolvedForumName = response.forum?.name ?? ""
        var threads = response.threadList ?? []
        // 作者可能不在 thread 里、而在单独的 user_list 里按 author_id 映射。
        if let users = response.userList, !users.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, String)? in
                guard !user.id.isEmpty, !user.name.isEmpty else { return nil }
                return (user.id, user.name)
            })
            for index in threads.indices {
                if (threads[index].authorName == "未知用户" || threads[index].authorName.isEmpty),
                   let name = byId[threads[index].authorId] {
                    threads[index].authorName = name
                }
            }
        }
        return ForumThreads(
            forumId: response.forum?.id ?? "",
            forumName: resolvedForumName.isEmpty ? forumName : resolvedForumName,
            threads: threads)
    }

    // 楼层列表：GET c/f/pb/page（tid, pn）。
    // 截图里详情页报“帖子可能已被删除”：先排除 tid 为空，再按参数组合依次重试
    // （只带 tid/pn → 加 rn/with_floor → 加 kz），某组成功即返回，不再把第一组的
    // 服务端报错直接当成帖子已删。全部失败才抛最后一次的原错。
    func fetchPosts(tid: String, page: Int) async throws -> [TiebaPost] {
        guard !tid.isEmpty else {
            throw TiebaError.server("帖子 id 为空（tid 为空），请回到列表重新打开这条帖子")
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
                    let byId = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (String, String)? in
                        guard !user.id.isEmpty, !user.name.isEmpty else { return nil }
                        return (user.id, user.name)
                    })
                    for index in posts.indices {
                        if (posts[index].authorName == "未知用户" || posts[index].authorName.isEmpty),
                           let name = byId[posts[index].authorId] {
                            posts[index].authorName = name
                        }
                    }
                }
                return posts
            } catch {
                lastError = error
            }
        }
        // 客户端接口全部报删帖时，改走网页版帖子页：只取楼层文字和作者名，
        // 至少把原帖的回复显示出来。网页也拿不到时，才抛客户端接口的原错。
        if let webPosts = try? await fetchPostsFromWeb(tid: tid, page: page), !webPosts.isEmpty {
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
