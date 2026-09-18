import Foundation
import MacToolsPluginKit
import SwiftUI

@MainActor
final class ClipboardItemShortcutStore: ObservableObject {
    enum Lifetime: Int, CaseIterable, Identifiable {
        case fiveMinutes = 300
        case oneHour = 3_600
        case oneDay = 86_400
        case untilRemoved = -1

        var id: Int { rawValue }
    }

    enum Source: String, Codable {
        case history
        case saved
        case snippet
    }

    struct Assignment: Codable, Equatable, Identifiable {
        let id: UUID
        let itemID: UUID
        let source: Source
        let expiresAt: Date?

        var definitionID: String { ClipboardItemShortcutStore.definitionID(for: itemID) }
    }

    private static let storageKey = "itemShortcutAssignments.v1"
    private let storage: any PluginStorage
    private let now: () -> Date
    private var expirationTask: Task<Void, Never>?
    @Published private(set) var assignments: [Assignment]
    var onRemoved: (([Assignment]) -> Void)?
    var onAssignmentsChanged: (() -> Void)?

    init(storage: any PluginStorage, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
        if let data = storage.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Assignment].self, from: data) {
            assignments = decoded
        } else {
            assignments = []
        }
        scheduleExpiration()
    }

    nonisolated static func definitionID(for itemID: UUID) -> String {
        "item-paste-\(itemID.uuidString.lowercased())"
    }

    nonisolated static func itemID(for definitionID: String) -> UUID? {
        let prefix = "item-paste-"
        guard definitionID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(definitionID.dropFirst(prefix.count)))
    }

    func assignment(for itemID: UUID) -> Assignment? {
        assignments.first {
            $0.itemID == itemID && ($0.expiresAt.map { $0 > now() } ?? true)
        }
    }

    var activeHistoryItemIDs: Set<UUID> {
        let currentDate = now()
        return Set(assignments.lazy.filter {
            $0.source == .history && ($0.expiresAt.map { $0 > currentDate } ?? true)
        }.map(\.itemID))
    }

    func isCurrent(_ id: UUID, itemID: UUID) -> Bool {
        assignment(for: itemID)?.id == id
    }

    @discardableResult
    func assign(itemID: UUID, source: Source, lifetime: Lifetime?) -> Assignment {
        let previous = assignments.first { $0.itemID == itemID }
        precondition(lifetime != nil || previous != nil)
        let assignment = Assignment(
            id: UUID(), itemID: itemID, source: source,
            expiresAt: lifetime.map { selected in
                selected == .untilRemoved ? nil : now().addingTimeInterval(TimeInterval(selected.rawValue))
            } ?? previous?.expiresAt
        )
        assignments.removeAll { $0.itemID == itemID }
        assignments.append(assignment)
        persist()
        scheduleExpiration()
        return assignment
    }

    func restore(_ assignment: Assignment?) {
        guard let assignment else { return }
        assignments.removeAll { $0.itemID == assignment.itemID }
        assignments.append(assignment)
        persist()
        scheduleExpiration()
    }

    @discardableResult
    func remove(itemID: UUID) -> Bool {
        let removed = assignments.filter { $0.itemID == itemID }
        guard !removed.isEmpty else { return false }
        onRemoved?(removed)
        assignments.removeAll { $0.itemID == itemID }
        persist()
        scheduleExpiration()
        return true
    }

    func removeMissingItems(historyIDs: Set<UUID>, savedIDs: Set<UUID>) {
        removeWhere { assignment in
            switch assignment.source {
            case .history: !historyIDs.contains(assignment.itemID)
            case .saved, .snippet: !savedIDs.contains(assignment.itemID)
            }
        }
    }

    func removeAll() {
        removeWhere { _ in true }
    }

    func expireIfNeeded() {
        removeWhere { $0.expiresAt.map { $0 <= now() } ?? false }
    }

    private func removeWhere(_ predicate: (Assignment) -> Bool) {
        let removed = assignments.filter(predicate)
        guard !removed.isEmpty else { return }
        onRemoved?(removed)
        assignments.removeAll(where: predicate)
        persist()
        scheduleExpiration()
    }

    private func persist() {
        storage.set(try? JSONEncoder().encode(assignments), forKey: Self.storageKey)
        onAssignmentsChanged?()
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        guard let next = assignments.compactMap(\.expiresAt).filter({ $0 > now() }).min() else { return }
        let interval = max(0, next.timeIntervalSince(now()))
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.expireIfNeeded()
        }
    }
}
