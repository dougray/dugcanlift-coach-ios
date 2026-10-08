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
    @State private var importKind: ImportKind = .backup
    @State private var exportDocument: BackupDocument?
    @State private var errorMessage: String?
    @State private var importNote: String?
    /// Restore deletes every client on the device before it imports, so it
    /// asks first, counted, as Remove client does.
    @State private var confirmingRestore = false

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
                Button("Restore from Backup") {
                    confirmingRestore = true
                }
                    .foregroundStyle(Theme.accent)
                Button("Import from the web app") {
                    importKind = .webLibrary
                    showingImporter = true
                }
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
        // Held to a readable width and centred on a wide screen; wider than
        // any phone, so no change there.
        .frame(maxWidth: AdaptiveLayout.readableWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        // The tab row above already names this screen, and the browser build
        // goes straight from its tabs into the content.
        .navigationBarTitleDisplayMode(.inline)
        .regularWidthTitle("Connect")
        .alert("Replace your clients?", isPresented: $confirmingRestore) {
            Button("Choose Backup", role: .destructive) {
                importKind = .backup
                showingImporter = true
            }
            Button("Save Backup First") { exportBackup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.restoreWarning(clients: (try? context.fetchCount(FetchDescriptor<Client>())) ?? 0))
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "coach-backup") { _ in }
        // One importer for both buttons, told apart by `importKind`. Two
        // `.fileImporter` modifiers on one view do not both work: SwiftUI
        // honours only the last, so "Restore from Backup" silently opened
        // nothing while "Import from the web app" worked.
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch importKind {
            case .backup: importBackup(result)
            case .webLibrary: importWebLibrary(result)
            }
        }
    }

    private enum ImportKind { case backup, webLibrary }

    private var inviteText: String {
        // With no name set, "I'm your coach, your coach on LIFT" said it twice.
        let intro = coachName.isEmpty ? "I'm your coach on LIFT" : "I'm \(coachName), your coach on LIFT"
        let email = coachEmail.isEmpty ? "[enter your email above]" : coachEmail
        return """
        Hi! \(intro). To share your training and \
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
            // Success used to be silent, and an earlier failure's message
            // stayed on screen beneath a restore that had worked.
            importNote = Self.restoredNote(clients: (try? context.fetchCount(FetchDescriptor<Client>())) ?? 0)
            errorMessage = nil
        } catch {
            errorMessage = "That doesn't look like a valid backup file."
            importNote = nil
        }
    }

    /// What the restore alert says. Clients are replaced; the recipe and
    /// workout library merges by id (see `BackupCodec.restore`), so only the
    /// roster is at stake. Static and pure so it can be tested.
    static func restoreWarning(clients: Int) -> String {
        let roster = clients == 0 ? "your roster"
            : clients == 1 ? "your 1 client and their logs" : "your \(clients) clients and their logs"
        return "Restoring replaces \(roster) with the backup's. This can't be undone, so save "
             + "a backup of this device first if you might want it back. Recipes and workouts "
             + "are merged: nothing in your library is deleted."
    }

    static func restoredNote(clients: Int) -> String {
        "Restored \(clients) client\(clients == 1 ? "" : "s"). Recipes and workouts in the backup "
            + "were added to your library."
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
                  // Said only when there are any: a coach who has never sent a
                  // plan from the browser should read the sentence they always
                  // read.
                  + (summary.sentPlans > 0
                     ? " Plus \(summary.sentPlans) plan\(summary.sentPlans == 1 ? "" : "s") "
                       + "you sent from the browser."
                     : "")
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
