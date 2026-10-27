import CryptoKit
import Foundation

// 数据模型层：UI 只依赖这些自有模型，不直接使用接口原始字段。
// 接口返回结构变化时，解析只改这里，UI 不动。
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
    let portrait: String

    enum CodingKeys: String, CodingKey {
        case id, name, userName = "user_name", userId = "user_id", uid, nickname, showNickname = "show_nickname", nameShow = "name_show", portrait
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
        // 头像：user_list 里的 portrait（如 tb.1.xxx），头像地址是
        // https://tb.himg.baidu.com/sys/portrait/item/<portrait>。
        self.portrait = container.flexibleString(forKey: .portrait)
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
    var authorPortrait: String
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
        var authorPortrait = ""
        if let author = try? container.decode(AuthorInfo.self, forKey: .author) {
            if !author.name.isEmpty { authorName = author.name }
            if !author.id.isEmpty { authorId = author.id }
            authorPortrait = author.portrait
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
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
    var authorPortrait: String
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
        self.authorPortrait = ""
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
        var authorPortrait = ""
        if let author = try? container.decode(AuthorInfo.self, forKey: .author) {
            if !author.name.isEmpty { authorName = author.name }
            if !author.id.isEmpty { authorId = author.id }
            authorPortrait = author.portrait
        } else if let name = try? container.decode(String.self, forKey: .author),
                  !name.isEmpty {
            authorName = name
        }
        self.authorName = authorName
        self.authorId = authorId
        self.authorPortrait = authorPortrait
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

