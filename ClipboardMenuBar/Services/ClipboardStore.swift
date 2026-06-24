import AppKit
import Foundation
import SwiftData

struct NextOpenPromotion: Equatable, Sendable {
    static let validityInterval: TimeInterval = 3 * 60

    let itemID: UUID
    let copiedAt: Date

    var expiresAt: Date {
        copiedAt.addingTimeInterval(Self.validityInterval)
    }

    func isEligible(at now: Date) -> Bool {
        now < expiresAt
    }
}

struct ClipboardCaptureToken: Sendable, Equatable {
    let id: UUID
    let signature: String
}

enum ClipboardCaptureReservation: Equatable {
    case existing(UUID)
    case alreadyInFlight(UUID)
    case new(ClipboardCaptureToken)
}

private struct InFlightCapture {
    let token: ClipboardCaptureToken
    var copiedAt: Date
}

private struct DirectPasteUse: Equatable {
    let signature: String
    let changeCount: Int
    let usedAt: Date

    func isExpired(at now: Date) -> Bool {
        now >= usedAt.addingTimeInterval(NextOpenPromotion.validityInterval)
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    private let modelContainer: ModelContainer?
    private let modelContext: ModelContext
    private let imageStorage: ImageStorage

    private var pendingNextOpenPromotions: [NextOpenPromotion] = []
    private var inFlightCaptures: [String: InFlightCapture] = [:]
    private var internalPasteboardChangeCounts: Set<Int> = []
    private var directPasteUses: [DirectPasteUse] = []

    init(modelContext: ModelContext, imageStorage: ImageStorage, modelContainer: ModelContainer? = nil) {
        self.modelContainer = modelContainer
        self.modelContext = modelContext
        self.imageStorage = imageStorage
    }

    func fetchItems(promoting promotions: [NextOpenPromotion] = []) -> [ClipboardItem] {
        let descriptor = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\ClipboardItem.createdAt, order: .reverse)])
        let all = (try? modelContext.fetch(descriptor)) ?? []
        let itemsByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let promoted = promotions.compactMap { itemsByID[$0.itemID] }
        let promotedIDs = Set(promoted.map(\.id))

        let pinned = all.filter { $0.isPinned && !promotedIDs.contains($0.id) }
        let unpinned = all.filter { !$0.isPinned && !promotedIDs.contains($0.id) }
        return promoted + pinned + unpinned
    }

    func latestItem() -> ClipboardItem? {
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\ClipboardItem.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func thumbnailImage(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image else { return nil }

        if let previewData = item.previewData,
           let previewImage = NSImage(data: previewData) {
            return previewImage
        }

        guard let imagePath = item.imagePath else { return nil }
        return imageStorage.loadImage(relativePath: imagePath)
    }

    func suppressCapture(changeCount: Int) {
        internalPasteboardChangeCounts.insert(changeCount)
    }

    func isCaptureSuppressed(changeCount: Int) -> Bool {
        internalPasteboardChangeCounts.contains(changeCount)
    }

    func consumeCaptureSuppression(changeCount: Int) -> Bool {
        internalPasteboardChangeCounts = internalPasteboardChangeCounts.filter { $0 >= changeCount }
        return internalPasteboardChangeCounts.remove(changeCount) != nil
    }

    func reserveExternalCapture(
        signature: String,
        copiedAt: Date = .now,
        changeCount: Int? = nil
    ) -> ClipboardCaptureReservation {
        let shouldPromote = shouldPromoteNextOpen(signature: signature, changeCount: changeCount, at: copiedAt)

        if var inFlight = inFlightCaptures[signature] {
            inFlight.copiedAt = copiedAt
            inFlightCaptures[signature] = inFlight
            if shouldPromote {
                enqueueNextOpenPromotion(itemID: inFlight.token.id, copiedAt: copiedAt)
            }
            return .alreadyInFlight(inFlight.token.id)
        }

        if let item = latestItem(), item.pasteboardSignature == signature {
            if shouldPromote {
                enqueueNextOpenPromotion(itemID: item.id, copiedAt: copiedAt)
            }
            return .existing(item.id)
        }

        let token = ClipboardCaptureToken(id: UUID(), signature: signature)
        inFlightCaptures[signature] = InFlightCapture(token: token, copiedAt: copiedAt)
        if shouldPromote {
            enqueueNextOpenPromotion(itemID: token.id, copiedAt: copiedAt)
        }
        return .new(token)
    }

    @discardableResult
    func markDirectPasteUsed(signature: String, changeCount: Int, at now: Date = .now) -> Bool {
        pruneDirectPasteUses(at: now)

        let use = DirectPasteUse(signature: signature, changeCount: changeCount, usedAt: now)
        if directPasteUses.contains(where: { $0.signature == signature && $0.changeCount == changeCount }) == false {
            directPasteUses.append(use)
        }

        let matchingIDs = itemIDs(matchingSignature: signature)
        let previousCount = pendingNextOpenPromotions.count
        pendingNextOpenPromotions.removeAll { matchingIDs.contains($0.itemID) }
        let removedMatchingPromotion = pendingNextOpenPromotions.count != previousCount

        pendingNextOpenPromotions.removeAll { !$0.isEligible(at: now) }
        pendingNextOpenPromotions.sort { $0.copiedAt > $1.copiedAt }

        if removedMatchingPromotion {
            objectWillChange.send()
        }
        return removedMatchingPromotion
    }

    func commitText(_ text: String, token: ClipboardCaptureToken) {
        guard let inFlight = inFlightCaptures[token.signature],
              inFlight.token == token else {
            removePendingPromotion(itemID: token.id)
            return
        }

        let item = ClipboardItem(
            id: token.id,
            createdAt: inFlight.copiedAt,
            kind: .text,
            textContent: text,
            pasteboardSignature: token.signature
        )
        modelContext.insert(item)
        inFlightCaptures[token.signature] = nil
        persist()
    }

    func commitImage(payload: StoredImagePayload, token: ClipboardCaptureToken) {
        guard let inFlight = inFlightCaptures[token.signature],
              inFlight.token == token else {
            imageStorage.deleteImage(relativePath: payload.relativePath)
            removePendingPromotion(itemID: token.id)
            return
        }

        let item = ClipboardItem(
            id: token.id,
            createdAt: inFlight.copiedAt,
            kind: .image,
            imagePath: payload.relativePath,
            imageWidth: payload.size.width,
            imageHeight: payload.size.height,
            previewData: payload.previewData,
            pasteboardSignature: token.signature
        )
        modelContext.insert(item)
        inFlightCaptures[token.signature] = nil
        persist()
    }

    func cancelCapture(_ token: ClipboardCaptureToken) {
        guard inFlightCaptures[token.signature]?.token == token else { return }
        inFlightCaptures[token.signature] = nil
        removePendingPromotion(itemID: token.id)
        objectWillChange.send()
    }

    func consumeEligibleNextOpenPromotions(at now: Date = .now) -> [NextOpenPromotion] {
        let eligible = pendingNextOpenPromotions
            .filter { $0.isEligible(at: now) }
            .sorted { $0.copiedAt > $1.copiedAt }

        pendingNextOpenPromotions.removeAll()
        return eligible
    }

    func finishPresentationSession(promotions: [NextOpenPromotion], at now: Date = .now) {
        for promotion in promotions where inFlightContains(itemID: promotion.itemID) && promotion.isEligible(at: now) {
            let existing = pendingNextOpenPromotions.first { $0.itemID == promotion.itemID }
            if let existing, existing.copiedAt >= promotion.copiedAt {
                continue
            }
            pendingNextOpenPromotions.removeAll { $0.itemID == promotion.itemID }
            pendingNextOpenPromotions.append(promotion)
        }
        pendingNextOpenPromotions.removeAll { !$0.isEligible(at: now) }
        pendingNextOpenPromotions.sort { $0.copiedAt > $1.copiedAt }
    }

    func pendingPromotionsForTesting() -> [NextOpenPromotion] {
        pendingNextOpenPromotions
    }

    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        try? modelContext.save()
        objectWillChange.send()
    }

    @discardableResult
    func clearAll() -> Int {
        let items = fetchItems().filter { !$0.isPinned }
        guard items.isEmpty == false else { return 0 }

        let deletedIDs = Set(items.map(\.id))
        items.forEach { item in
            imageStorage.deleteImage(relativePath: item.imagePath)
            modelContext.delete(item)
        }
        pendingNextOpenPromotions.removeAll { deletedIDs.contains($0.itemID) }
        removeInFlightCaptures(itemIDs: deletedIDs)
        try? modelContext.save()
        objectWillChange.send()
        return items.count
    }

    func image(for item: ClipboardItem) -> NSImage? {
        guard let path = item.imagePath else { return nil }
        return imageStorage.loadImage(relativePath: path)
    }

    func delete(_ item: ClipboardItem) {
        imageStorage.deleteImage(relativePath: item.imagePath)
        removePendingPromotion(itemID: item.id)
        removeInFlightCaptures(itemIDs: [item.id])
        modelContext.delete(item)
        try? modelContext.save()
        objectWillChange.send()
    }

    private func enqueueNextOpenPromotion(itemID: UUID, copiedAt: Date) {
        pendingNextOpenPromotions.removeAll { !$0.isEligible(at: copiedAt) }
        pendingNextOpenPromotions.removeAll { $0.itemID == itemID }
        pendingNextOpenPromotions.append(NextOpenPromotion(itemID: itemID, copiedAt: copiedAt))
        pendingNextOpenPromotions.sort { $0.copiedAt > $1.copiedAt }
    }

    private func shouldPromoteNextOpen(signature: String, changeCount: Int?, at now: Date) -> Bool {
        pruneDirectPasteUses(at: now)
        guard let changeCount else { return true }
        return directPasteUses.contains { $0.signature == signature && $0.changeCount == changeCount } == false
    }

    private func pruneDirectPasteUses(at now: Date) {
        directPasteUses.removeAll { $0.isExpired(at: now) }
    }

    private func removePendingPromotion(itemID: UUID) {
        pendingNextOpenPromotions.removeAll { $0.itemID == itemID }
    }

    private func itemIDs(matchingSignature signature: String) -> Set<UUID> {
        var ids = Set<UUID>()
        if let inFlight = inFlightCaptures[signature] {
            ids.insert(inFlight.token.id)
        }

        let descriptor = FetchDescriptor<ClipboardItem>()
        let items = (try? modelContext.fetch(descriptor)) ?? []
        for item in items where item.pasteboardSignature == signature {
            ids.insert(item.id)
        }
        return ids
    }

    private func removeInFlightCaptures(itemIDs: Set<UUID>) {
        inFlightCaptures = inFlightCaptures.filter { !itemIDs.contains($0.value.token.id) }
    }

    private func inFlightContains(itemID: UUID) -> Bool {
        inFlightCaptures.values.contains { $0.token.id == itemID }
    }

    private func persist() {
        try? modelContext.save()
        objectWillChange.send()
    }
}
