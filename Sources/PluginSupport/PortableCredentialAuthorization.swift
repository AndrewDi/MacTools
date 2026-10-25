import Foundation
import MacToolsPluginKit

/// Destination-only endpoint grants. Import cannot attach an existing credential to a new service.
@MainActor
struct PortableCredentialAuthorization {
    static let key = "preferences-backup.credential-endpoints.v1"
    let storage: any PluginStorage

    static var field: PortablePreferenceField {
        .data(Data("{}".utf8), maximumBytes: 262_144) { data in
            guard let grants = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
            return grants.count <= 256 && grants.allSatisfy {
                PortablePreferencesValidation.identifier($0.key) && PortablePreferencesValidation.endpoint($0.value)
            }
        }
    }

    var isInitialized: Bool {
        guard let data = storage.data(forKey: Self.key) else { return false }
        return Self.field.accepts(.data(data))
    }

    func revoking(_ profileIDs: Set<String>) -> Data? {
        try? JSONEncoder().encode(grants.filter { !profileIDs.contains($0.key) })
    }

    private var grants: [String: String] {
        storage.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func allows(profileID: String, baseURL: String) -> Bool {
        guard let granted = grants[profileID] else { return false }
        return canonical(granted) == canonical(baseURL)
    }

    /// Call before any import, once for existing destination profiles; no Keychain access.
    func seedIfNeeded(profiles: [String: String], store: PortablePreferencesStore) {
        guard storage.object(forKey: Self.key) == nil,
              let data = try? JSONEncoder().encode(profiles) else { return }
        _ = store.commit([Self.key: .data(data)])
    }

    /// Only a locally entered key may authorize a changed endpoint.
    func granting(_ profiles: [String: String]) -> Data? {
        let merged = grants.merging(profiles, uniquingKeysWith: { _, local in local })
        return try? JSONEncoder().encode(merged)
    }

    private func canonical(_ endpoint: String) -> String {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return endpoint }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? endpoint
    }
}
