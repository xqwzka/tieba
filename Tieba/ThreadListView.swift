import SwiftUI

// 仿 NodeSeek 列表样式：顶部新帖子/吧名/加号、横向排序标签（选中橙色下划线）、
// 每行头像首字 + 标题 + 作者·时间·吧名 + 右侧浏览/回复数。
struct ThreadListView: View {
    let forumName: String

    @EnvironmentObject private var session: SessionStore
    @State private var threads: [TiebaThread] = []
    @State private var forumId = ""
    @State private var currentPage = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var noMore = false
    @State private var errorMessage: String?
    @State private var showCompose = false
    @State private var showLoginAlert = false
    @State private var sort: ThreadSort = .replyTime

    // 顶部三个标签就是三种排序：热门 / 回复时间 / 新帖。
    // 排序只针对已加载的帖子（翻页加载后会重新排），不是服务端排序。
    private var visibleThreads: [TiebaThread] {
        sort.sort(threads)
    }

    private func timeText(for thread: TiebaThread) -> String {
        switch sort {
        case .newest:
            return relativeTiebaTime(thread.createTime)
        case .replyTime, .hot:
            return relativeTiebaTime(thread.lastTime)
        }
    }

    private func openCompose() {
        if session.isLoggedIn {
            showCompose = true
        } else {
            showLoginAlert = true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏：左新帖子、中间吧名、右加号，都是发帖入口。
            HStack {
                Button("新帖子", action: openCompose)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.4)))
                Spacer()
                Text(forumName)
                    .font(.headline)
                Spacer()
                Button(action: openCompose) {
                    Image(systemName: "plus")
                        .font(.title3)
                        .padding(10)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // 横向排序标签：选中黑字加粗 + 橙色下划线，未选中灰字。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(ThreadSort.allCases, id: \.self) { mode in
                        Button {
                            sort = mode
                        } label: {
                            VStack(spacing: 4) {
                                Text(mode.rawValue)
                                    .font(sort == mode ? .headline : .body)
                                    .foregroundStyle(sort == mode ? .primary : .secondary)
                                Rectangle()
                                    .fill(sort == mode ? Color.orange : Color.clear)
                                    .frame(height: 3)
                                    .frame(width: 24)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            Divider()

            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(visibleThreads) { thread in
                    NavigationLink {
                        ThreadDetailView(thread: thread, forumId: forumId, forumName: forumName)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            avatar(for: thread.authorName)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.title.isEmpty ? "(无标题)" : thread.title)
                                    .lineLimit(2)
                                Text("\(thread.authorName) · \(timeText(for: thread)) · \(forumName)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            HStack(spacing: 12) {
                                Label(countText(thread.viewNum), systemImage: "eye")
                                Label(countText(thread.replyNum), systemImage: "message")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !threads.isEmpty && !noMore {
                    Button(isLoadingMore ? "加载中…" : "加载更多") {
                        loadMore()
                    }
                    .disabled(isLoadingMore)
                }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("请先登录", isPresented: $showLoginAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("发帖需要先登录。关闭本页回到登录页扫码。")
        }
        .sheet(isPresented: $showCompose) {
            ComposeView(mode: .thread(forumId: forumId, forumName: forumName)) {
                reload()
            }
        }
        .onAppear {
            if threads.isEmpty {
                reload()
            }
        }
        .overlay {
            if isLoading && threads.isEmpty {
                ProgressView()
            }
        }
    }

    // 头像：没有头像接口时用作者名首字 + 固定色盘，保证每行都有圆头像。
    private func avatar(for name: String) -> some View {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .red, .brown]
        let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let initial = name.isEmpty ? "?" : String(name.prefix(1))
        return Text(initial)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(palette[abs(hash) % palette.count].opacity(0.8)))
    }

    private func reload() {
        currentPage = 1
        noMore = false
        load(page: 1, replace: true)
    }

    private func loadMore() {
        guard !isLoadingMore, !noMore else { return }
        load(page: currentPage + 1, replace: false)
    }

    private func load(page: Int, replace: Bool) {
        if replace {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        errorMessage = nil
        Task {
            do {
                let result = try await TiebaClient.shared.fetchThreads(forumName: forumName, page: page)
                forumId = result.forumId
                if replace {
                    threads = result.threads
                } else {
                    threads.append(contentsOf: result.threads)
                }
                if result.threads.isEmpty {
                    noMore = true
                    if replace {
                        errorMessage = "这个吧暂无帖子"
                    }
                } else {
                    currentPage = page
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            isLoadingMore = false
        }
    }
}

// 相对时间：刚刚 / X 分钟前 / X 小时前 / MM-dd，贴合截图的第二行样式。
func relativeTiebaTime(_ timestamp: Int) -> String {
    guard timestamp > 0 else { return "" }
    let seconds = Int(Date().timeIntervalSince1970) - timestamp
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86400 { return "\(seconds / 3600) 小时前" }
    return formatTiebaTime(timestamp)
}

// 计数：10000 以上用 k，如 144.4k；以下直接显示数字。
func countText(_ value: Int) -> String {
    if value >= 10000 {
        return String(format: "%.1fk", Double(value) / 1000.0)
    }
    return "\(value)"
}
