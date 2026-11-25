import Foundation

/// Layouts imported from Steam: the files exactly as Steam published them, with a small index.
/// Community layouts are fetched by their Steam Workshop ID through Steam's public file-details
/// service, which needs no account or key.
///
/// Use from the main thread.
final class SteamLayoutLibrary: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        let id: String
        var title: String
        var controllerType: String
        var workshopID: String?
        var importedAt: Date
        /// What the layout asks for that OpenNOW cannot do.
        var notes: [String]
        /// Inputs the player re-bound after importing, by `SteamInputConfig.overrideKey`.
        var overrides: [String: String] = [:]

        init(id: String, title: String, controllerType: String, workshopID: String?, importedAt: Date, notes: [String]) {
            self.id = id
            self.title = title
            self.controllerType = controllerType
            self.workshopID = workshopID
            self.importedAt = importedAt
            self.notes = notes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            controllerType = try container.decodeIfPresent(String.self, forKey: .controllerType) ?? ""
            workshopID = try container.decodeIfPresent(String.self, forKey: .workshopID)
            importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date(timeIntervalSince1970: 0)
            notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
            overrides = try container.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:]
        }
    }

    enum ImportFailure: LocalizedError, Equatable {
        case noIdentifier
        case notFound
        case notALayout
        case tooLarge
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noIdentifier: return String(localized: "That does not contain a Steam layout link or ID.")
            case .notFound: return String(localized: "Steam has no public layout with that ID.")
            case .notALayout: return String(localized: "That file is not a Steam Input layout.")
            case .tooLarge: return String(localized: "That file is too large to be a layout.")
            case .network(let message): return String(localized: "Steam could not be reached: \(message)")
            }
        }
    }

    static let shared = SteamLayoutLibrary()
    static let maximumFileBytes = 2_000_000

    @Published private(set) var entries: [Entry] = []

    private let directory: URL
    private var configs: [String: SteamInputConfig] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SteamLayouts", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        }
        // What is unsupported depends on this version of the app, not the one that imported the file.
        var changed = false
        for index in entries.indices {
            guard let notes = published(entries[index].id)?.notes, notes != entries[index].notes else { continue }
            entries[index].notes = notes
            changed = true
        }
        if changed { saveIndex() }
    }

    /// Per-game choices are remembered under the game's title, as on-screen control layouts are.
    static func gameKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The Workshop ID in a pasted link or number. `steam://controllerconfig/<app>/<id>` and
    /// Workshop page links both end in it.
    static func workshopID(in text: String) -> String? {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else {
                if current.count >= 6 { runs.append(current) }
                current = ""
            }
        }
        if current.count >= 6 { runs.append(current) }
        return runs.last.flatMap { $0.count <= 20 ? $0 : nil }
    }

    /// The layout as it runs: the published file with the player's re-bindings applied.
    func config(for id: String) -> SteamInputConfig? {
        guard let entry = entries.first(where: { $0.id == id }), var config = published(id) else { return nil }
        config.apply(overrides: entry.overrides)
        return config
    }

    /// The layout exactly as published.
    func published(_ id: String) -> SteamInputConfig? {
        guard entries.contains(where: { $0.id == id }) else { return nil }
        if let cached = configs[id] { return cached }
        guard let text = try? String(contentsOf: fileURL(id), encoding: .utf8),
              let config = try? SteamInputConfig(vdf: text) else { return nil }
        configs[id] = config
        return config
    }

    /// Re-binds one input of an imported layout, or with nil puts it back as published.
    func setOverride(_ action: ControllerAction?, layout id: String, set: Int,
                     source: SteamInputConfig.Source, input: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].overrides[SteamInputConfig.overrideKey(set: set, source: source, input: input)] = action?.token
        saveIndex()
    }

    /// Saves a layout file. Importing the same Workshop layout again replaces the earlier copy.
    @discardableResult
    func add(vdf text: String, workshopID: String? = nil, fallbackTitle: String = "") throws -> Entry {
        guard text.utf8.count <= Self.maximumFileBytes else { throw ImportFailure.tooLarge }
        guard let config = try? SteamInputConfig(vdf: text) else { throw ImportFailure.notALayout }
        let existing = workshopID.flatMap { id in entries.first { $0.workshopID == id } }
        let title = config.title.isEmpty || config.title.hasPrefix("#") ? fallbackTitle : config.title
        var entry = Entry(
            id: existing?.id ?? UUID().uuidString,
            title: title.isEmpty ? String(localized: "Steam Layout") : String(title.prefix(120)),
            controllerType: config.controllerType,
            workshopID: workshopID,
            importedAt: Date(),
            notes: config.notes
        )
        entry.overrides = existing?.overrides ?? [:]
        try Data(text.utf8).write(to: fileURL(entry.id), options: .atomic)
        configs[entry.id] = config
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        saveIndex()
        return entry
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        configs[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
        saveIndex()
    }

    /// Downloads the layout a Steam link or Workshop ID points at and saves it.
    @discardableResult
    func importFromSteam(_ reference: String, session: URLSession = .shared) async throws -> Entry {
        guard let id = Self.workshopID(in: reference) else { throw ImportFailure.noIdentifier }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("itemcount=1&publishedfileids[0]=\(id)".utf8)
        request.timeoutInterval = 20
        let details: PublishedFile
        do {
            let (data, _) = try await session.data(for: request)
            guard let file = try JSONDecoder().decode(DetailsResponse.self, from: data).response.publishedfiledetails.first else {
                throw ImportFailure.notFound
            }
            details = file
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            throw ImportFailure.network(error.localizedDescription)
        }
        // Result 1 is success; the link must be Steam's own HTTPS download for a layout file.
        guard details.result == 1, let link = details.file_url, let url = URL(string: link), url.scheme == "https",
              url.host?.hasSuffix("steamusercontent.com") == true else { throw ImportFailure.notFound }
        guard details.consumer_app_id == 241100 else { throw ImportFailure.notALayout }
        if let size = details.file_size?.value, size > Self.maximumFileBytes { throw ImportFailure.tooLarge }
        let text: String
        do {
            let (data, _) = try await session.data(from: url)
            guard data.count <= Self.maximumFileBytes else { throw ImportFailure.tooLarge }
            text = String(decoding: data, as: UTF8.self)
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            throw ImportFailure.network(error.localizedDescription)
        }
        return try await MainActor.run { try add(vdf: text, workshopID: id, fallbackTitle: details.title ?? "") }
    }

    private struct DetailsResponse: Decodable {
        struct Body: Decodable { let publishedfiledetails: [PublishedFile] }
        let response: Body
    }

    private struct PublishedFile: Decodable {
        let result: Int?
        let file_url: String?
        let title: String?
        let consumer_app_id: Int?
        let file_size: FlexibleInt?
    }

    /// Steam sends some numbers as numbers and some as strings.
    private struct FlexibleInt: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                value = number
            } else {
                value = Int(try container.decode(String.self)) ?? 0
            }
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("vdf")
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

extension AppSettings {
    /// The layout to use for a game: the one chosen for that game, else the general choice.
    /// An empty ID means the layout made in OpenNOW.
    func steamControllerLayoutID(forGame title: String?) -> String {
        title.flatMap { steamControllerGameLayouts[SteamLayoutLibrary.gameKey($0)] } ?? steamControllerActiveLayout
    }

    func steamControllerConfig(forGame title: String?) -> SteamInputConfig {
        SteamLayoutLibrary.shared.config(for: steamControllerLayoutID(forGame: title))
            ?? steamControllerLayout.steamInputConfig
    }
}
