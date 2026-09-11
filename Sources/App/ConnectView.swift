import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ConnectView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("coachName") private var coachName = ""
    @AppStorage("coachEmail") private var coachEmail = ""

    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: BackupDocument?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $coachName)
                    .foregroundStyle(Theme.textPrimary)
                TextField("Email", text: $coachEmail)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.textPrimary)
            } header: {
                Text("Your Info")
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            Section {
                Button("Save Backup") { exportBackup() }
                    .foregroundStyle(Theme.accent)
                Button("Restore from Backup") { showingImporter = true }
                    .foregroundStyle(Theme.accent)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            } header: {
                Text("Backup")
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            Section {
                Text("Everything stays on this device. There's no account and no server — a backup file is the only way to move your roster to another device.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.background)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Connect")
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "coach-backup") { _ in }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            importBackup(result)
        }
    }

    private func exportBackup() {
        do {
            let data = try BackupCodec.export(from: context)
            exportDocument = BackupDocument(data: data)
            showingExporter = true
        } catch {
            errorMessage = "Couldn't create a backup: \(error.localizedDescription)"
        }
    }

    private func importBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Couldn't access that file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            try BackupCodec.restore(from: data, into: context)
        } catch {
            errorMessage = "That doesn't look like a valid backup file."
        }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
