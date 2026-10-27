import SwiftUI

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

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(threads) { thread in
                NavigationLink {
                    ThreadDetailView(thread: thread, forumId: forumId, forumName: forumName)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.title.isEmpty ? "(无标题)" : thread.title)
                            .lineLimit(2)
                        HStack {
                            Text(thread.authorName)
                            Text("回复 \(thread.replyNum)")
                            Text(formatTiebaTime(thread.createTime))
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if !threads.isEmpty && !noMore {
                Button(isLoadingMore ? "加载中…" : "加载更多") {
                    loadMore()
                }
                .disabled(isLoadingMore)
            }
        }
        .navigationTitle(forumName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("发帖") {
                    if session.isLoggedIn {
                        showCompose = true
                    } else {
                        showLoginAlert = true
                    }
                }
            }
        }
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
