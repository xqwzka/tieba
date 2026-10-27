import Foundation

// 数据模型层：UI 只依赖这些模型，不直接使用接口原始字段。
// 验证状态（2026-10-27 实测）：
//   frs 帖子列表：已验证通过（带签名可返回 thread_list）
//   pb 帖子详情：未验证通过（匿名和登录后均报删帖，见 TiebaClient 注释）
//   forum/like 关注：匿名返回空，登录后未验证通过
//   发帖/回复/tbs：需要登录态，未在真机验证通过

enum TiebaError: LocalizedError {
    case notLoggedIn
    case alreadySubmitting
    case missingTBS
    case invalidResponse
    case network(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "请先登录"
        case .alreadySubmitting: return "正在提交，请稍候"
        case .missingTBS: return "发帖凭证获取失败，请重新登录"
        case .invalidResponse: return "贴吧返回数据无法解析"
        case .network(let message): return "网络错误：\(message)"
        case .server(let message): return message
        }
    }
}

extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return ""
    }

    func flexibleInt(forKey key: Key) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) ?? 0 }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        return 0
    }
}

struct AuthorInfo: Decodable {
    let id: String
    let name: String
    let portrait: String

    enum CodingKeys: String, CodingKey {
        case id, name, portrait
        case userName = "user_name", userId = "user_id", uid, nickname
        case showNickname = "show_nickname", nameShow = "name_show"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = container.flexibleString(forKey: .id)
        let userId = container.flexibleString(forKey: .userId)
        let uid = container.flexibleString(forKey: .uid)
        self.id = !id.isEmpty ? id : (!userId.isEmpty ? userId : uid)
        let candidates = [
            container.flexibleString(forKey: .name),
            container.flexibleString(forKey: .nameShow),
            container.flexibleString(forKey: .userName),
            container.flexibleString(forKey: .nickname),
            container.flexibleString(forKey: .showNickname),
        ]
        self.name = candidates.first { !$0.isEmpty } ?? ""
        self.portrait = container.flexibleString(forKey: .portrait)
    }
}

struct ForumInfo: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case fid, fname
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = container.flexibleString(forKey: .id)
        let fid = container.flexibleString(forKey: .fid)
        self.id = !id.isEmpty ? id : fid
        let name = container.flexibleString(forKey: .name)
        let fname = container.flexibleString(forKey: .fname)
        self.name = !name.isEmpty ? name : fname
    }
}

struct TiebaThread: Identifiable, Decodable {
    var id: String { tid }
    let tid: String
    let title: String
    var authorName: String
    var authorId: String
    var authorPortrait: String
    let replyNum: Int
    let viewNum: Int
    let createTime: Int
    let lastTime: Int

    enum CodingKeys: String, CodingKey {
        case tid, title, author
        case replyNum = "reply_num", viewNum = "view_num"
        case createTime = "create_time", lastTime = "last_time"
        case authorId = "author_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tid = container.flexibleString(forKey: .tid)
        title = container.flexibleString(forKey: .title)
        var authorName = "未知用户"
        var authorId = container.flexibleString(forKey: .authorId)
        var authorPortrait = ""
        if let author = try? container.decode(AuthorInfo.self, forKey: .author) {
            if !author.name.isEmpty { authorName = author.name }
            if !author.id.isEmpty { authorId = author.id }
            authorPortrait = author.portrait
        } else if let name = try? container.decode(String.self, forKey: .author), !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        self.authorId = authorId
        self.authorPortrait = authorPortrait
        replyNum = container.flexibleInt(forKey: .replyNum)
        viewNum = container.flexibleInt(forKey: .viewNum)
        let createTime = container.flexibleInt(forKey: .createTime)
        let lastTime = container.flexibleInt(forKey: .lastTime)
        self.createTime = createTime != 0 ? createTime : lastTime
        self.lastTime = lastTime != 0 ? lastTime : createTime
    }
}

enum ThreadSort: String, CaseIterable {
    case hot = "热门"
    case replyTime = "回复时间"
    case newest = "新帖"

    func sort(_ threads: [TiebaThread]) -> [TiebaThread] {
        switch self {
        case .hot: return threads.sorted { $0.replyNum != $1.replyNum ? $0.replyNum > $1.replyNum : $0.lastTime > $1.lastTime }
        case .replyTime: return threads.sorted { $0.lastTime > $1.lastTime }
        case .newest: return threads.sorted { $0.createTime > $1.createTime }
        }
    }
}

struct ContentFragment: Decodable {
    let type: Int
    let text: String
    let originSrc: String

    init(type: Int, text: String, originSrc: String) {
        self.type = type
        self.text = text
        self.originSrc = originSrc
    }

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

struct TiebaPost: Identifiable, Decodable {
    var id: String { pid }
    let pid: String
    let floor: Int
    var authorName: String
    var authorId: String
    var authorPortrait: String
    let time: Int
    let content: [ContentFragment]
    let subPostCount: Int

    var text: String { content.filter { $0.type == 0 }.map { $0.text }.joined() }
    var imageURLs: [String] { content.filter { $0.type == 3 }.map { $0.originSrc }.filter { !$0.isEmpty } }

    enum CodingKeys: String, CodingKey {
        case pid, floor, author, time, content
        case subPostCount = "sub_post_number", authorId = "author_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = container.flexibleString(forKey: .pid)
        floor = container.flexibleInt(forKey: .floor)
        var authorName = "未知用户"
        var authorId = container.flexibleString(forKey: .authorId)
        var authorPortrait = ""
        if let author = try? container.decode(AuthorInfo.self, forKey: .author) {
            if !author.name.isEmpty { authorName = author.name }
            if !author.id.isEmpty { authorId = author.id }
            authorPortrait = author.portrait
        } else if let name = try? container.decode(String.self, forKey: .author), !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        self.authorId = authorId
        self.authorPortrait = authorPortrait
        time = container.flexibleInt(forKey: .time)
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
        } else if let name = try? container.decode(String.self, forKey: .author), !name.isEmpty {
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
        case threadList = "thread_list", userList = "user_list"
    }
}

struct PbResponse: Decodable {
    let postList: [TiebaPost]?
    let userList: [AuthorInfo]?

    enum CodingKeys: String, CodingKey {
        case postList = "post_list", userList = "user_list"
    }
}

struct FloorResponse: Decodable {
    let subpostList: [TiebaSubPost]?
    let userList: [AuthorInfo]?

    enum CodingKeys: String, CodingKey {
        case subpostList = "subpost_list", userList = "user_list"
    }
}

struct ForumThreads {
    let forumId: String
    let forumName: String
    let threads: [TiebaThread]
}
