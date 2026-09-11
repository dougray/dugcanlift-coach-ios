import SwiftUI
import SwiftData

struct PasteLinkView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                } header: {
                    Text("Paste the link a client sent you")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importLink() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func importLink() {
        do {
            let payload = try ShareLinkCodec.decode(link: text.trimmingCharacters(in: .whitespacesAndNewlines))
            try ShareLinkImporter.importPayload(payload, into: context)
            dismiss()
        } catch {
            errorMessage = "That doesn't look like a valid LIFT log link. Double-check you copied the whole thing."
        }
    }
}
