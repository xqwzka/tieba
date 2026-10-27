import SwiftUI

struct ComposeView: View {
    enum Mode {
        case thread(forumId: String, forumName: String)
    }

    let mode: Mode
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("标题", text: $title)
                }
                Section("内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 160)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("发帖")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "发布中" : "发布") {
                        submit()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSubmitting)
                }
            }
        }
    }

    private func submit() {
        guard case .thread(let forumId, let forumName) = mode else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await TiebaClient.shared.addThread(
                    forumId: forumId, forumName: forumName,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    content: content.trimmingCharacters(in: .whitespacesAndNewlines))
                onDone()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
