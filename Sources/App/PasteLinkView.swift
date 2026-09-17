import SwiftUI
import SwiftData
import LiftCore

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
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.chipRadius))
                } header: {
                    Text("Paste the link a client sent you")
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.background)

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    .listRowBackground(Theme.background)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Import Log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importLink() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .tint(Theme.accent)
        .liftAppearance()
    }

    private func importLink() {
        do {
            _ = try ShareLinkImporter.importLink(text, into: context)
            dismiss()
        } catch {
            errorMessage = ShareLinkImporter.invalidLinkMessage
        }
    }
}
