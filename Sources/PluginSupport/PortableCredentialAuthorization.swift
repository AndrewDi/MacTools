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
                validGrant(profileID: $0.key, endpoint: $0.value)
            }
        }
    }

    // These destination-only grants retain URL components supported by existing local clients.
    // Portable payloads still use the stricter endpoint validator and cannot supply this map.
    private static func validGrant(profileID: String, endpoint: String) -> Bool {
        guard PortablePreferencesValidation.identifier(profileID), endpoint.utf8.count <= 262_144,
              let url = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host?.isEmpty == false, url.url != nil else { return false }
        return url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
    }

    var isInitialized: Bool {
        guard let data = storage.data(forKey: Self.key) else { return false }
        return Self.field.accepts(.data(data))
    }

    /// Revoke before writing so an interrupted replacement cannot reuse an old endpoint grant.
    /// Restore grants after failure only when a fresh read proves the secret is unchanged.
    func replaceCredential(
        for profileIDs: Set<String>? = nil,
        store: PortablePreferencesStore,
        load: () throws -> String?,
        save: () throws -> Void
    ) throws {
        let previousGrants = storage.data(forKey: Self.key)
        let previousKey = try? load()
        let retainedGrants = profileIDs.map { ids in grants.filter { !ids.contains($0.key) } } ?? [:]
        guard let revoked = try? JSONEncoder().encode(retainedGrants),
              store.commit([Self.key: .data(revoked)]) else { throw CocoaError(.fileWriteUnknown) }
        do {
            try save()
        } catch {
            if let previousKey, let currentKey = try? load(), currentKey == previousKey,
               let previousGrants {
                _ = store.commit([Self.key: .data(previousGrants)])
            }
            throw error
        }
    }

    private var grants: [String: String] {
        storage.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func allows(profileID: String, baseURL: String) -> Bool {
        guard let granted = grants[profileID] else { return false }
        return canonical(granted) == canonical(baseURL)
    }

    /// Call before any import, once for existing destination profiles; no Keychain access.
    func seedIfNeeded(profiles: [String: String], store: PortablePreferencesStore) -> Bool {
        guard storage.object(forKey: Self.key) == nil else { return isInitialized }
        guard let data = try? JSONEncoder().encode(profiles.filter { Self.validGrant(profileID: $0.key, endpoint: $0.value) }) else { return false }
        return store.commit([Self.key: .data(data)])
    }

    /// Only a locally entered key may authorize a changed endpoint.
    func granting(_ profiles: [String: String]) -> Data? {
        let validProfiles = profiles.filter { Self.validGrant(profileID: $0.key, endpoint: $0.value) }
        let merged = grants.merging(validProfiles, uniquingKeysWith: { _, local in local })
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
