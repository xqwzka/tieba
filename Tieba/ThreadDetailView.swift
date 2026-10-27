import SwiftUI

struct ThreadDetailView: View {
    let thread: TiebaThread
    let forumId: String
    let forumName: String

    @EnvironmentObject private var session: SessionStore
    @State private var posts: [TiebaPost] = []
    @State private var currentPage = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var noMore = false
    @State private var errorMessage: String?
    @State private var replyText = ""
    @State private var isSubmittingReply = false
    @State private var onlyLandlord = false
    @State private var showLoginAlert = false

    // 只看楼主：本地过滤，作者名与帖子作者相同才保留。
    private var visiblePosts: [TiebaPost] {
        guard onlyLandlord else { return posts }
        return posts.filter { $0.authorName == thread.authorName }
    }

    var body: some View {
        VStack(spacing: 0) {
            Toggle("只看楼主", isOn: $onlyLandlord)
                .padding(.horizontal)
                .padding(.vertical, 8)
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if visiblePosts.isEmpty && !isLoading {
                    Text(onlyLandlord ? "楼主暂无发言" : "暂无楼层")
                        .foregroundStyle(.secondary)
                }
                ForEach(visiblePosts) { post in
                    PostRow(post: post, tid: thread.tid, forumId: forumId, forumName: forumName)
                }
            }
            if !posts.isEmpty && !noMore {
                Button(isLoadingMore ? "加载中…" : "加载更多楼层") {
                    loadMore()
                }
                .disabled(isLoadingMore)
                .padding(.vertical, 8)
            }
            Divider()
            HStack {
                TextField("回帖…", text: $replyText)
                    .textFieldStyle(.roundedBorder)
                Button(isSubmittingReply ? "发送中" : "发送") {
                    submitReply()
                }
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmittingReply)
            }
            .padding()
        }
        .navigationTitle(thread.title.isEmpty ? "帖子详情" : thread.title)
        .alert("请先登录", isPresented: $showLoginAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("回帖需要先登录。关闭本页回到登录页扫码。")
        }
        .onAppear {
            if posts.isEmpty {
                reload()
            }
        }
        .overlay {
            if isLoading && posts.isEmpty {
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
                let fetched = try await TiebaClient.shared.fetchPosts(tid: thread.tid, page: page)
                if replace {
                    posts = fetched
                } else {
                    posts.append(contentsOf: fetched)
                }
                if fetched.isEmpty {
                    noMore = true
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

    private func submitReply() {
        guard session.isLoggedIn else {
            showLoginAlert = true
            return
        }
        let content = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSubmittingReply = true
        errorMessage = nil
        Task {
            do {
                try await TiebaClient.shared.addPost(
                    forumId: forumId, forumName: forumName, tid: thread.tid, content: content)
                replyText = ""
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmittingReply = false
        }
    }
}

// 单个楼层：文字、图片、楼中楼列表与楼中楼输入框。
struct PostRow: View {
    let post: TiebaPost
    let tid: String
    let forumId: String
    let forumName: String

    @EnvironmentObject private var session: SessionStore
    @State private var expanded = false
    @State private var subPosts: [TiebaSubPost] = []
    @State private var subPage = 1
    @State private var subLoading = false
    @State private var subNoMore = false
    @State private var subError: String?
    @State private var subInput = ""
    @State private var subSubmitting = false
    @State private var showLoginAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(post.authorName)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(post.floor)楼")
                Text(formatTiebaTime(post.time))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if !post.text.isEmpty {
                Text(post.text)
            }
            ForEach(post.imageURLs, id: \.self) { urlString in
                if let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            Text("图片加载失败").font(.footnote).foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                }
            }
            Button(expanded ? "收起楼中楼" : "楼中楼（\(post.subPostCount)）") {
                expanded.toggle()
                if expanded && subPosts.isEmpty {
                    loadSubPosts(page: 1, replace: true)
                }
            }
            .font(.footnote)
            if expanded {
                if let subError {
                    Text(subError).foregroundStyle(.red).font(.footnote)
                }
                ForEach(subPosts) { sub in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(sub.authorName).font(.footnote.bold())
                            Text(formatTiebaTime(sub.time)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(sub.contentText).font(.subheadline)
                    }
                    .padding(.leading, 8)
                }
                if subLoading {
                    ProgressView().padding(.leading, 8)
                } else if !subPosts.isEmpty && !subNoMore {
                    Button("加载更多楼中楼") {
                        loadSubPosts(page: subPage + 1, replace: false)
                    }
                    .font(.footnote)
                }
                HStack {
                    TextField("回复这层楼…", text: $subInput)
                        .textFieldStyle(.roundedBorder)
                    Button(subSubmitting ? "发送中" : "发送") {
                        submitSubPost()
                    }
                    .disabled(subInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subSubmitting)
                }
            }
        }
        .alert("请先登录", isPresented: $showLoginAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("楼中楼回复需要先登录。")
        }
    }

    private func loadSubPosts(page: Int, replace: Bool) {
        subLoading = true
        subError = nil
        Task {
            do {
                let fetched = try await TiebaClient.shared.fetchSubPosts(tid: tid, pid: post.pid, page: page)
                if replace {
                    subPosts = fetched
                } else {
                    subPosts.append(contentsOf: fetched)
                }
                if fetched.isEmpty {
                    subNoMore = true
                } else {
                    subPage = page
                }
            } catch {
                subError = error.localizedDescription
            }
            subLoading = false
        }
    }

    private func submitSubPost() {
        guard session.isLoggedIn else {
            showLoginAlert = true
            return
        }
        let content = subInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        subSubmitting = true
        subError = nil
        Task {
            do {
                try await TiebaClient.shared.addComment(
                    forumId: forumId, forumName: forumName, tid: tid, pid: post.pid, content: content)
                subInput = ""
                subNoMore = false
                loadSubPosts(page: 1, replace: true)
            } catch {
                subError = error.localizedDescription
            }
            subSubmitting = false
        }
    }
}
