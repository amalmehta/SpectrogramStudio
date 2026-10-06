import SwiftUI

/// Small feedback form. Saves locally; optionally opens a pre-filled GitHub issue in the browser.
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var kind = "Idea"
    @State private var message = ""
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Feedback").font(.title3.weight(.semibold))
            Picker("Kind", selection: $kind) {
                ForEach(["Idea", "Bug", "Question"], id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text(saved ? "Saved. Thank you!" : "Saved on this Mac only (\(FeedbackStore.fileURL.path(percentEncoded: false))). Nothing is sent unless you choose GitHub.")
                .font(.caption).foregroundStyle(saved ? .green : .secondary)
                .lineLimit(2).truncationMode(.middle)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open as GitHub Issue") { submit(openIssue: true) }.disabled(message.isEmpty)
                Button("Save") { submit(openIssue: false) }.keyboardShortcut(.defaultAction).disabled(message.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func submit(openIssue: Bool) {
        let entry = FeedbackStore.Entry(date: Date(), kind: kind, message: message)
        do {
            try FeedbackStore.save(entry)
            if openIssue { openURL(FeedbackStore.issueURL(for: entry)) }
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
