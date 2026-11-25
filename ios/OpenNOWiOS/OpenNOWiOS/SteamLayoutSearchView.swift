#if os(iOS)
import SwiftUI

/// Searches Steam for community layouts for a game and imports the one the player picks.
struct SteamLayoutSearchView: View {
    /// Called with each layout once it has been imported.
    let onImport: (SteamLayoutLibrary.Entry) -> Void
    @ObservedObject private var library = SteamLayoutLibrary.shared
    @State private var key = SteamLayoutSearch.apiKey
    @State private var game: String
    @State private var words = ""
    @State private var controllerType = ""
    @State private var results: [SteamLayoutSearchResult] = []
    @State private var searching = false
    @State private var searched = false
    @State private var importingID: String?
    @State private var message: String?

    init(gameTitle: String?, onImport: @escaping (SteamLayoutLibrary.Entry) -> Void) {
        self.onImport = onImport
        _game = State(initialValue: gameTitle ?? "")
    }

    var body: some View {
        Form {
            Section {
                SecureField("Steam Web API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: key) { SteamLayoutSearch.apiKey = $0 }
                Link("Get a Free Key from Steam", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
            } footer: {
                Text("Steam only answers searches that carry a Web API key. Any Steam account can create one: sign in, enter any domain name such as localhost, and copy the key here. It is kept in this device's keychain and sent only to Steam. Importing by link or ID does not need it.")
            }

            Section {
                TextField("Game", text: $game)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                TextField("Words in the Layout's Name (Optional)", text: $words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                Picker("Made For", selection: $controllerType) {
                    Text("Any Controller").tag("")
                    Text("Steam Controller").tag("controller_triton")
                    Text("Steam Deck").tag("controller_neptune")
                }
                Button(searching ? "Searching…" : "Search") { search() }
                    .disabled(searching || key.isEmpty || game.trimmingCharacters(in: .whitespaces).isEmpty)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Use the game's name as Steam shows it. Games that are not on Steam, such as World of Warcraft, are found by the name players gave their shortcut, so try the plain name.")
            }

            if !results.isEmpty {
                Section("Layouts") {
                    ForEach(results) { result in row(result) }
                }
            } else if searched, !searching, message == nil {
                Section {
                    Text("No public layouts were found for that game.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Find Layouts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ result: SteamLayoutSearchResult) -> some View {
        let imported = library.entries.contains { $0.workshopID == result.id }
        var details = [result.controllerName]
        if result.subscriptions > 0 { details.append(String(localized: "\(result.subscriptions) users")) }
        if !result.features.isEmpty { details.append(result.features.joined(separator: ", ")) }
        return Button {
            importLayout(result)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.title.isEmpty ? result.id : result.title)
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    if importingID == result.id {
                        ProgressView()
                    } else if imported {
                        Image(systemName: "checkmark.circle.fill")
                            .accessibilityLabel("Imported")
                    }
                }
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if result.usesNativeActions {
                    Text("Built on the game's own Steam Input actions; back buttons, menus and trackpad bindings may do nothing here.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !result.summary.isEmpty {
                    Text(result.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .disabled(importingID != nil)
    }

    private func search() {
        guard !searching, !key.isEmpty, !game.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        message = nil
        Task { @MainActor in
            defer {
                searching = false
                searched = true
            }
            do {
                results = try await SteamLayoutSearch.search(
                    game: game, text: words, controllerType: controllerType.isEmpty ? nil : controllerType, key: key)
            } catch {
                results = []
                message = error.localizedDescription
            }
        }
    }

    private func importLayout(_ result: SteamLayoutSearchResult) {
        guard importingID == nil else { return }
        importingID = result.id
        message = nil
        Task { @MainActor in
            defer { importingID = nil }
            do {
                let entry = try await library.importFromSteam(result.id)
                onImport(entry)
                message = String(localized: "Imported \(entry.title). It is now the layout in use.")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
#endif
