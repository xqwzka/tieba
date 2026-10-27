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
    @State private var showWebDetail = false

    // 只看楼主：优先按作者 id 过滤（用户名可能昵称/用户名混用），id 为空时退回按作者名。
    private var visiblePosts: [TiebaPost] {
        guard onlyLandlord else { return posts }
        if !thread.authorId.isEmpty {
            return posts.filter { $0.authorId == thread.authorId }
        }
        return posts.filter { $0.authorName == thread.authorName }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 详情顶部直接显示楼主用户名和吧名，不再只剩标题。
            HStack {
                Text("楼主：\(thread.authorName)")
                    .font(.subheadline.bold())
                Spacer()
                Text(forumName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("回复 \(thread.replyNum)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Toggle("只看楼主", isOn: $onlyLandlord)
                .padding(.horizontal)
                .padding(.vertical, 8)
            List {
                // 实测结论：匿名查详情会被服务端直接拒绝（350004，文案就是
                // “帖子可能已被删除”，连公告帖也一样），不是帖子真的被删。
                // 所以未登录时先明说，避免把通用报错当成帖子状态。
                if !session.isLoggedIn {
                    Text("未登录：贴吧会拒绝匿名查看详情，显示的“帖子可能已被删除”不代表帖子真的被删。请先返回首页点“关闭”去扫码登录，再重新打开这条帖子。")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if visiblePosts.isEmpty && !isLoading {
                    Text(onlyLandlord ? "楼主暂无发言" : "暂无楼层")
                        .foregroundStyle(.secondary)
                    // 原生接口拿不到楼层时，直接用官方网页版看：楼层、作者、头像都在。
                    Button("用网页版打开这条帖子") {
                        showWebDetail = true
                    }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("网页版") {
                    showWebDetail = true
                }
            }
        }
        .sheet(isPresented: $showWebDetail) {
            WebDetailView(tid: thread.tid)
        }
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
                // 报错里不再带 tid：用户要看的是用户名，不是帖子 id。
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
                AvatarView(name: post.authorName, portrait: post.authorPortrait, size: 32)
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
