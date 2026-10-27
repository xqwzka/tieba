import SwiftUI

// 仿 NodeSeek 列表样式：顶部新帖子/吧名/加号、横向排序标签（选中橙色下划线）、
// 每行头像 + 标题 + 作者·相对时间·吧名 + 右侧浏览/回复数。
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

    private var visibleThreads: [TiebaThread] { sort.sort(threads) }

    private func timeText(for thread: TiebaThread) -> String {
        switch sort {
        case .newest: return relativeTiebaTime(thread.createTime)
        case .replyTime, .hot: return relativeTiebaTime(thread.lastTime)
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(ThreadSort.allCases, id: \.self) { mode in
                        Button {
                            // 切排序要重新向服务端要一页：只在客户端重排旧的一页，
                            // “新帖”永远排不出全吧最新发表的帖子。
                            sort = mode
                            currentPage = 1
                            noMore = false
                            load(page: 1, replace: true, sort: mode)
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
                            AvatarView(name: thread.authorName, portrait: thread.authorPortrait)
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
            .refreshable {
                // 下拉刷新绕过 60 秒缓存，直接向服务端要最新列表。
                await refreshNow()
            }
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
            // 打开列表就自动刷新，不再只在空页时加载、其余时间吃 60 秒缓存。
            Task { await refreshNow() }
        }
        .overlay {
            if isLoading && threads.isEmpty {
                ProgressView()
            }
        }
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

    private func refreshNow() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await TiebaClient.shared.fetchThreads(forumName: forumName, page: 1, force: true, sort: sort)
            forumId = result.forumId
            threads = result.threads
            currentPage = 1
            noMore = result.threads.isEmpty
            if result.threads.isEmpty {
                errorMessage = "这个吧暂无帖子"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(page: Int, replace: Bool, sort: ThreadSort? = nil) {
        if replace {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        errorMessage = nil
        let effectiveSort = sort ?? self.sort
        Task {
            do {
                let result = try await TiebaClient.shared.fetchThreads(forumName: forumName, page: page, sort: effectiveSort)
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
