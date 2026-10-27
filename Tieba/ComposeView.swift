import SwiftUI

// 发主题、回帖、楼中楼共用的编辑器。
enum ComposeMode {
    case thread(forumId: String, forumName: String)
    case post(forumId: String, forumName: String, tid: String)
    case comment(forumId: String, forumName: String, tid: String, pid: String)
}

struct ComposeView: View {
    let mode: ComposeMode
    var onSuccess: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var titleText = ""
    @State private var contentText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var showsTitleField: Bool {
        if case .thread = mode { return true }
        return false
    }

    private var navigationTitle: String {
        switch mode {
        case .thread: return "发帖"
        case .post: return "回帖"
        case .comment: return "楼中楼回复"
        }
    }

    private var placeholder: String {
        switch mode {
        case .thread: return "写点什么…"
        case .post: return "回复楼主…"
        case .comment: return "回复这层楼…"
        }
    }

    private var canSubmit: Bool {
        let content = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isSubmitting else { return false }
        if showsTitleField {
            return !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if showsTitleField {
                    TextField("标题", text: $titleText)
                        .textFieldStyle(.roundedBorder)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $contentText)
                        .frame(minHeight: 200)
                    if contentText.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button(isSubmitting ? "提交中…" : "提交") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                Spacer()
            }
            .padding()
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                switch mode {
                case .thread(let forumId, let forumName):
                    try await TiebaClient.shared.addThread(
                        forumId: forumId, forumName: forumName, title: title, content: content)
                case .post(let forumId, let forumName, let tid):
                    try await TiebaClient.shared.addPost(
                        forumId: forumId, forumName: forumName, tid: tid, content: content)
                case .comment(let forumId, let forumName, let tid, let pid):
                    try await TiebaClient.shared.addComment(
                        forumId: forumId, forumName: forumName, tid: tid, pid: pid, content: content)
                }
                onSuccess()
                dismiss()
            } catch {
                // 服务端 error_msg 原样显示，不吞错。
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
