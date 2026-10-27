import SwiftUI

// 时间戳（秒）转简短显示；0 或缺失时不显示。
func formatTiebaTime(_ timestamp: Int) -> String {
    guard timestamp > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
}

struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var forums: [String] = []
    @State private var newForumName = ""

    private let savedForumsKey = "savedForums"

    var body: some View {
        NavigationStack {
            List {
                if !session.isLoggedIn {
                    Text("未登录：可以阅读，发帖和回复需要先登录")
                        .foregroundStyle(.secondary)
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
            .navigationTitle("贴吧")
            .toolbar {
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
                // 只存吧名数组，不存任何凭证。
                forums = UserDefaults.standard.stringArray(forKey: savedForumsKey) ?? []
            }
        }
    }

    private func saveForums() {
        UserDefaults.standard.set(forums, forKey: savedForumsKey)
    }
}
