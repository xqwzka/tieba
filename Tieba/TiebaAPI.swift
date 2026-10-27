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
        if let value = try? decodeIfPresent(String.self, forKey: key), let text = value {
            return text
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key), let number = value {
            return String(number)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), let number = value {
            return String(Int(number))
        }
        return ""
    }

    func flexibleInt(forKey key: Key) -> Int {
        if let value = try? decodeIfPresent(Int.self, forKey: key), let number = value {
            return number
        }
        if let value = try? decodeIfPresent(String.self, forKey: key),
           let text = value, let number = Int(text) {
            return number
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), let number = value {
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
    let name: String

    enum CodingKeys: String, CodingKey { case name, userName = "user_name" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = container.flexibleString(forKey: .name)
        let userName = container.flexibleString(forKey: .userName)
        self.name = !name.isEmpty ? name : userName
    }
}

// 帖子列表项（c/f/frs/page 的 thread_list）
struct TiebaThread: Identifiable, Decodable {
    var id: String { tid }
    let tid: String
    let title: String
    let authorName: String
    let replyNum: Int
    let createTime: Int

    enum CodingKeys: String, CodingKey {
        case tid, title, author
        case replyNum = "reply_num"
        case createTime = "create_time"
        case lastTime = "last_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tid = container.flexibleString(forKey: .tid)
        title = container.flexibleString(forKey: .title)
        var authorName = "未知用户"
        if let author = try? container.decode(AuthorInfo.self, forKey: .author),
           !author.name.isEmpty {
            authorName = author.name
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        replyNum = container.flexibleInt(forKey: .replyNum)
        let createTime = container.flexibleInt(forKey: .createTime)
        let lastTime = container.flexibleInt(forKey: .lastTime)
        self.createTime = createTime != 0 ? createTime : lastTime
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
    let authorName: String
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = container.flexibleString(forKey: .pid)
        floor = container.flexibleInt(forKey: .floor)
        var authorName = "未知用户"
        if let author = try? container.decode(AuthorInfo.self, forKey: .author),
           !author.name.isEmpty {
            authorName = author.name
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        time = container.flexibleInt(forKey: .time)
        content = (try? container.decodeIfPresent([ContentFragment].self, forKey: .content)) ?? []
        subPostCount = container.flexibleInt(forKey: .subPostCount)
    }
}

// 楼中楼（c/f/pb/floor 的 subpost_list，content 多为纯字符串）
struct TiebaSubPost: Identifiable, Decodable {
    var id: String { pid }
    let pid: String
    let authorName: String
    let time: Int
    let contentText: String

    enum CodingKeys: String, CodingKey {
        case pid, author, time, content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = container.flexibleString(forKey: .pid)
        var authorName = "未知用户"
        if let author = try? container.decode(AuthorInfo.self, forKey: .author),
           !author.name.isEmpty {
            authorName = author.name
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
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

    enum CodingKeys: String, CodingKey {
        case forum
        case threadList = "thread_list"
    }
}

struct PbResponse: Decodable {
    let postList: [TiebaPost]?

    enum CodingKeys: String, CodingKey {
        case postList = "post_list"
    }
}

struct FloorResponse: Decodable {
    let subpostList: [TiebaSubPost]?

    enum CodingKeys: String, CodingKey {
        case subpostList = "subpost_list"
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
        return ForumThreads(
            forumId: response.forum?.id ?? "",
            forumName: resolvedForumName.isEmpty ? forumName : resolvedForumName,
            threads: response.threadList ?? [])
    }

    // 楼层列表：GET c/f/pb/page（tid, pn）
    func fetchPosts(tid: String, page: Int) async throws -> [TiebaPost] {
        let data = try await request(
            path: "/c/f/pb/page", params: ["tid": tid, "pn": String(page)], method: "GET")
        let response = try decode(data, as: PbResponse.self)
        return response.postList ?? []
    }

    // 楼中楼分页：GET c/f/pb/floor（tid, pid, pn）
    func fetchSubPosts(tid: String, pid: String, page: Int) async throws -> [TiebaSubPost] {
        let data = try await request(
            path: "/c/f/pb/floor",
            params: ["tid": tid, "pid": pid, "pn": String(page)], method: "GET")
        let response = try decode(data, as: FloorResponse.self)
        return response.subpostList ?? []
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
