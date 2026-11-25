import Foundation
import Security

/// One community layout found on Steam.
struct SteamLayoutSearchResult: Identifiable, Equatable {
    /// The Steam Workshop ID, which is what a layout is imported by.
    let id: String
    var title: String
    var summary: String
    /// Steam's name for the pad it was made on, such as `controller_triton`.
    var controllerType: String
    /// What it uses, from Steam's own tags: gyro, touch menus and so on.
    var features: [String]
    /// Made of the game's native Steam Input actions rather than keys and buttons.
    var usesNativeActions: Bool
    var subscriptions: Int

    var controllerName: String {
        switch controllerType {
        case "controller_triton": return String(localized: "Steam Controller")
        case "controller_neptune": return String(localized: "Steam Deck")
        case "controller_steamcontroller_gordon": return String(localized: "Steam Controller (2015)")
        case "controller_ps5", "controller_ps5_edge": return "DualSense"
        case "controller_ps4": return "DualShock 4"
        case "controller_xboxone", "controller_xbox360", "controller_xboxelite": return "Xbox"
        case "controller_switch_pro", "controller_switch2_pro": return "Switch Pro"
        case "": return String(localized: "Any Controller")
        default: return controllerType.replacingOccurrences(of: "controller_", with: "")
        }
    }
}

/// Finds community layouts through Steam's file query service. Unlike fetching one layout by its
/// ID, searching needs a Steam Web API key, which every Steam account can create for free; the
/// player's key is kept in the keychain and sent only to Steam.
enum SteamLayoutSearch {
    enum Failure: LocalizedError, Equatable {
        case keyRejected
        case network(String)

        var errorDescription: String? {
            switch self {
            case .keyRejected: return String(localized: "Steam did not accept that Web API key.")
            case .network(let message): return String(localized: "Steam could not be reached: \(message)")
            }
        }
    }

    /// Steam's app for controller layouts, and its file type for them in queries.
    private static let layoutsApp = 241100
    private static let controllerBindings = 15
    private static let pageSize = 40
    private static let keychainService = "OpenNOW.SteamWebAPIKey"

    static var apiKey: String {
        get {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
                kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService]
            SecItemDelete(base as CFDictionary)
            let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            var item = base
            item[kSecValueData] = Data(key.utf8)
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    /// The request for one game. Steam files a layout under the game's app ID, or under the
    /// lower-case name of the shortcut for a game that is not on Steam.
    static func query(app: String, text: String, controllerType: String?) -> [String: Any] {
        var query: [String: Any] = [
            "appid": layoutsApp, "filetype": controllerBindings, "numperpage": pageSize,
            "return_kv_tags": true, "return_tags": true, "return_short_description": true,
            "required_kv_tags": [["key": "app", "value": app], ["key": "visibility", "value": "public"]]
        ]
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 12 ranks by how well the text matches; 9 by how many people have used the layout.
        query["query_type"] = words.isEmpty ? 9 : 12
        if !words.isEmpty { query["search_text"] = words }
        if let controllerType, !controllerType.isEmpty { query["requiredtags"] = [controllerType] }
        return query
    }

    /// Reads a query response. Steam sends numbers as text here, so both are accepted.
    static func results(from data: Data) -> [SteamLayoutSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let files = response["publishedfiledetails"] as? [[String: Any]] else { return [] }
        func text(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
        return files.compactMap { file in
            let id = text(file["publishedfileid"])
            guard text(file["result"]) == "1", !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            let tags = (file["tags"] as? [[String: Any]] ?? []).map { text($0["tag"]) }
            return SteamLayoutSearchResult(
                id: id,
                title: text(file["title"]),
                summary: text(file["short_description"]),
                controllerType: tags.first { $0.hasPrefix("controller_") && $0 != "controller_native" } ?? "",
                features: tags.filter { $0.hasPrefix("feature_") }.map { featureName(String($0.dropFirst("feature_".count))) },
                usesNativeActions: tags.contains("controller_native"),
                subscriptions: Int(text(file["lifetime_subscriptions"])) ?? 0
            )
        }
    }

    /// Steam's tags run words together, and misspell one.
    private static func featureName(_ tag: String) -> String {
        ["keboard": "keyboard", "touchmenu": "touch menu", "radialmenu": "radial menu", "actionset": "action sets",
         "modeshift": "mode shift", "activator": "press types"][tag] ?? tag
    }

    /// Steam's app IDs for a game name, best match first, from the store's public search.
    static func steamApps(named name: String, session: URLSession = .shared) async -> [String] {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [.init(name: "term", value: name), .init(name: "cc", value: "us"), .init(name: "l", value: "en")]
        guard let url = components.url, let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.prefix(2).compactMap { ($0["id"] as? NSNumber)?.stringValue }
    }

    /// Layouts for a game by name: those filed under the name itself, for games that are not on
    /// Steam, and those filed under the Steam games the name matches.
    static func search(game: String, text: String = "", controllerType: String? = nil, key: String,
                       session: URLSession = .shared) async throws -> [SteamLayoutSearchResult] {
        let name = game.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return [] }
        var found: [SteamLayoutSearchResult] = []
        for app in [name] + (await steamApps(named: name, session: session)) {
            let input = try JSONSerialization.data(withJSONObject: query(app: app, text: text, controllerType: controllerType))
            var components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
            components.queryItems = [.init(name: "key", value: key.trimmingCharacters(in: .whitespacesAndNewlines)),
                                     .init(name: "input_json", value: String(decoding: input, as: UTF8.self))]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if status == 401 || status == 403 { throw Failure.keyRejected }
                for result in results(from: data) where !found.contains(where: { $0.id == result.id }) {
                    found.append(result)
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.network(error.localizedDescription)
            }
        }
        return found
    }
}
