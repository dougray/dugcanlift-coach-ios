import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LiftCore

struct ConnectView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("coachName") private var coachName = ""
    @AppStorage("coachEmail") private var coachEmail = ""

    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingWebImporter = false
    @State private var exportDocument: BackupDocument?
    @State private var errorMessage: String?
    @State private var importNote: String?

    var body: some View {
        Form {
            Section {
                AppearancePicker()
                    .listRowBackground(Theme.surface)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your phone's light or dark setting.")
            }

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
                Text(inviteText)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                ShareLink(item: inviteText) {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                }
                .tint(Theme.accent)
            } header: {
                Text("Invite a Client")
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            Section {
                Button("Save Backup") { exportBackup() }
                    .foregroundStyle(Theme.accent)
                Button("Restore from Backup") { showingImporter = true }
                    .foregroundStyle(Theme.accent)
                Button("Import from the web app") { showingWebImporter = true }
                    .foregroundStyle(Theme.accent)
                if let importNote {
                    Text(importNote).foregroundStyle(Theme.textSecondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            } header: {
                Text("Backup")
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            Section {
                Text("Everything stays on this device. There's no account and no server — "
                     + "a backup file is the only way to move your roster, your recipes and "
                     + "your workouts to another device.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.background)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        // The tab row above already names this screen, and the browser build
        // goes straight from its tabs into the content.
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "coach-backup") { _ in }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            importBackup(result)
        }
        .fileImporter(isPresented: $showingWebImporter, allowedContentTypes: [.json]) { result in
            importWebLibrary(result)
        }
    }

    private var inviteText: String {
        let name = coachName.isEmpty ? "your coach" : coachName
        let email = coachEmail.isEmpty ? "[enter your email above]" : coachEmail
        return """
        Hi! I'm \(name), your coach on LIFT. To share your training and \
        nutrition log with me, open LIFT, go to Settings, and use \
        "Send to Coach" with this email address: \(email)
        """
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

    private func importWebLibrary(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Couldn't access that file."
                importNote = nil
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let summary = try WebLibraryImporter.importLibrary(
                from: try Data(contentsOf: url), into: context)
            importNote = summary.isEmpty
                ? "That backup had no library in it. Save a fresh one from the web app first."
                : "Brought in \(summary.recipes) recipes, \(summary.meals) planned meals, "
                  + "\(summary.routines) workouts and \(summary.sessions) sessions."
            errorMessage = nil
        } catch {
            errorMessage = "That doesn't look like a LIFT Coach backup."
            importNote = nil
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
