import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var forums: [String] = []
    @State private var followedForums: [String] = []
    @State private var followedError: String?
    @State private var isLoadingFollowed = false
    @State private var isSorting = false
    @State private var newForumName = ""

    private let savedForumsKey = "savedForums"
    private let followedOrderKey = "followedForumsOrder"

    var body: some View {
        NavigationStack {
            List {
                if !session.isLoggedIn {
                    Text("未登录：可以阅读，发帖和回复需要先登录")
                        .foregroundStyle(.secondary)
                }
                if session.isLoggedIn {
                    Section("我关注的吧") {
                        if isLoadingFollowed {
                            ProgressView()
                        } else if followedForums.isEmpty {
                            Text(followedError ?? "暂无关注的吧，或关注列表拉取失败，下方仍可用本地保存的吧")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(followedForums, id: \.self) { forum in
                            NavigationLink(forum) {
                                ThreadListView(forumName: forum)
                            }
                        }
                        .onMove { source, destination in
                            followedForums.move(fromOffsets: source, toOffset: destination)
                            saveFollowedOrder()
                        }
                    }
                    Section {
                        Button("刷新关注的吧") {
                            loadFollowed()
                        }
                        .disabled(isLoadingFollowed)
                    }
                }
                Section("我的吧") {
                    ForEach(forums, id: \.self) { forum in
                        NavigationLink(forum) {
                            ThreadListView(forumName: forum)
                        }
                    }
                    .onDelete { indexSet in
                        forums.remove(atOffsets: indexSet)
                        saveForums()
                    }
                    .onMove { source, destination in
                        forums.move(fromOffsets: source, toOffset: destination)
                        saveForums()
                    }
                }
                Section("添加吧") {
                    HStack {
                        TextField("输入吧名，如：李毅", text: $newForumName)
                        Button("添加") {
                            let name = newForumName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty, !forums.contains(name) else { return }
                            forums.append(name)
                            newForumName = ""
                            saveForums()
                        }
                        .disabled(newForumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .environment(\.editMode, .constant(isSorting ? .active : .inactive))
            .navigationTitle("贴吧")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isSorting ? "完成" : "排序") {
                        isSorting.toggle()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if session.isLoggedIn {
                        Button("退出登录") {
                            session.logout()
                        }
                    } else {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                forums = UserDefaults.standard.stringArray(forKey: savedForumsKey) ?? []
                if session.isLoggedIn && followedForums.isEmpty {
                    loadFollowed()
                }
            }
        }
    }

    private func saveForums() {
        UserDefaults.standard.set(forums, forKey: savedForumsKey)
    }

    private func saveFollowedOrder() {
        UserDefaults.standard.set(followedForums, forKey: followedOrderKey)
    }

    private func loadFollowed() {
        isLoadingFollowed = true
        followedError = nil
        Task {
            do {
                let fetched = try await TiebaClient.shared.fetchFollowedForums()
                if fetched.isEmpty {
                    followedError = "关注列表为空或接口未返回吧名"
                } else {
                    let savedOrder = UserDefaults.standard.stringArray(forKey: followedOrderKey) ?? []
                    let ordered = savedOrder.filter { fetched.contains($0) }
                    let rest = fetched.filter { !savedOrder.contains($0) }
                    followedForums = ordered + rest
                    saveFollowedOrder()
                }
            } catch {
                followedError = "关注列表拉取失败：\(error.localizedDescription)"
            }
            isLoadingFollowed = false
        }
    }
}
