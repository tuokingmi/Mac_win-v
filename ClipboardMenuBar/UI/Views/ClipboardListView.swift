import Carbon
import SwiftUI

final class ClipboardPanelInputState: ObservableObject {
    @Published var isVSelectionModeActive = false
}

enum ClipboardRowClickAction: Equatable {
    case updateSelection
    case pasteSingleItem
}

struct ClipboardSelectionState: Equatable {
    var focusedItemID: UUID?
    var selectedItemIDs: Set<UUID> = []

    var hasSelection: Bool {
        selectedItemIDs.isEmpty == false
    }

    mutating func toggleSelection(itemID: UUID) {
        focusedItemID = itemID
        if selectedItemIDs.contains(itemID) {
            selectedItemIDs.remove(itemID)
        } else {
            selectedItemIDs.insert(itemID)
        }
    }

    mutating func ordinaryClick(itemID: UUID) {
        focusedItemID = itemID
        selectedItemIDs.removeAll()
    }

    mutating func handleRowClick(
        itemID: UUID,
        isVSelectionModeActive: Bool
    ) -> ClipboardRowClickAction {
        if isVSelectionModeActive {
            toggleSelection(itemID: itemID)
            return .updateSelection
        }

        ordinaryClick(itemID: itemID)
        return .pasteSingleItem
    }

    mutating func moveFocus(direction: Int, orderedIDs: [UUID]) {
        guard orderedIDs.isEmpty == false else {
            focusedItemID = nil
            return
        }

        let currentIndex = focusedItemID.flatMap { orderedIDs.firstIndex(of: $0) } ?? 0
        let nextIndex = min(max(currentIndex + direction, 0), orderedIDs.count - 1)
        focusedItemID = orderedIDs[nextIndex]
    }

    mutating func repair(orderedIDs: [UUID]) {
        let validIDs = Set(orderedIDs)
        selectedItemIDs.formIntersection(validIDs)

        if let focusedItemID, validIDs.contains(focusedItemID) {
            return
        }

        focusedItemID = orderedIDs.first
    }

    func selectedItemsInDisplayOrder(from items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }
}

struct ClipboardListView: View {
    private enum ClearButtonState: Equatable {
        case idle
        case success
    }

    @ObservedObject var clipboardStore: ClipboardStore
    @ObservedObject var panelController: PanelController
    @ObservedObject var inputState: ClipboardPanelInputState
    let activePromotions: [NextOpenPromotion]

    @State private var selectionState = ClipboardSelectionState()
    @State private var clearButtonState: ClearButtonState = .idle
    @State private var clearFeedbackTask: Task<Void, Never>?

    private var items: [ClipboardItem] {
        clipboardStore.fetchItems(promoting: activePromotions)
    }

    private var itemIDs: [UUID] {
        items.map(\.id)
    }

    private var selectedItemsInDisplayOrder: [ClipboardItem] {
        selectionState.selectedItemsInDisplayOrder(from: items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clipboard History")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    handleClear()
                } label: {
                    ZStack(alignment: .trailing) {
                        Text("Clear")
                            .opacity(clearButtonState == .idle ? 1 : 0)

                        Image(systemName: "checkmark")
                            .opacity(clearButtonState == .success ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.18), value: clearButtonState)
                }
                .buttonStyle(.borderless)
            }

            if panelController.accessibilityEnabled == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Accessibility permission is required for automatic paste.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Refresh") {
                            panelController.notifyPermissionStateChanged()
                        }
                        Button("Grant") {
                            panelController.requestAccessibilityPermission()
                        }
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if items.isEmpty {
                ContentUnavailableView("No clipboard history", systemImage: "clipboard", description: Text("Copy text or images to start building history."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(items, id: \.id) { item in
                                Button {
                                    handleRowClick(item)
                                } label: {
                                    ClipboardRowView(
                                        item: item,
                                        thumbnailImage: clipboardStore.thumbnailImage(for: item),
                                        isFocused: selectionState.focusedItemID == item.id,
                                        isMultiSelected: selectionState.selectedItemIDs.contains(item.id)
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        clipboardStore.togglePin(item)
                                    } label: {
                                        Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                                    }
                                    Button(role: .destructive) {
                                        clipboardStore.delete(item)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .id(item.id)
                            }
                        }
                    }
                    .onChange(of: selectionState.focusedItemID) { _, newValue in
                        guard let newValue else { return }
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            HStack {
                Text("按住 V 点击多选 · ↑↓ 移动 · Enter 粘贴 · Esc 关闭")
                    .foregroundStyle(.secondary)
                Spacer()
                if selectionState.hasSelection {
                    Button("粘贴 \(selectionState.selectedItemIDs.count) 项") {
                        pasteCurrentSelection()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.footnote)
        }
        .padding(16)
        .frame(width: 460, height: 520)
        .background(
            KeyEventHandlingView(
                onKeyDown: handleKeyDown,
                onKeyUp: handleKeyUp
            )
        )
        .onAppear {
            panelController.notifyPermissionStateChanged()
            selectionState.repair(orderedIDs: itemIDs)
        }
        .onDisappear {
            clearFeedbackTask?.cancel()
            clearFeedbackTask = nil
            clearButtonState = .idle
        }
        .onChange(of: itemIDs) { _, newIDs in
            selectionState.repair(orderedIDs: newIDs)
        }
    }

    private func handleRowClick(_ item: ClipboardItem) {
        let action = selectionState.handleRowClick(
            itemID: item.id,
            isVSelectionModeActive: inputState.isVSelectionModeActive
        )

        if action == .updateSelection {
            return
        }

        _ = panelController.paste(item)
    }

    private func handleClear() {
        let clearedCount = clipboardStore.clearAll()
        guard clearedCount > 0 else { return }

        selectionState.repair(orderedIDs: itemIDs)
        showClearSuccessFeedback()
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_ANSI_V) {
            inputState.isVSelectionModeActive = true
            return true
        }

        guard items.isEmpty == false else {
            if event.keyCode == 53 {
                panelController.hide()
                return true
            }
            return false
        }

        switch event.keyCode {
        case 125:
            selectionState.moveFocus(direction: 1, orderedIDs: itemIDs)
            return true
        case 126:
            selectionState.moveFocus(direction: -1, orderedIDs: itemIDs)
            return true
        case 36, 76:
            if selectionState.hasSelection {
                pasteCurrentSelection()
            } else if let focusedItemID = selectionState.focusedItemID,
                      let item = items.first(where: { $0.id == focusedItemID }) {
                _ = panelController.paste(item)
            }
            return true
        case 53:
            panelController.hide()
            return true
        default:
            return false
        }
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_ANSI_V) else { return false }
        inputState.isVSelectionModeActive = false
        return true
    }

    private func pasteCurrentSelection() {
        let selectedItems = selectedItemsInDisplayOrder
        guard selectedItems.isEmpty == false else { return }
        _ = panelController.paste(selectedItems)
    }

    private func showClearSuccessFeedback() {
        clearFeedbackTask?.cancel()

        withAnimation(.easeInOut(duration: 0.18)) {
            clearButtonState = .success
        }

        clearFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard Task.isCancelled == false else { return }

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) {
                    clearButtonState = .idle
                }
                clearFeedbackTask = nil
            }
        }
    }
}

struct KeyEventHandlingView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    let onKeyUp: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onKeyUp = onKeyUp
    }
}

final class KeyView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onKeyUp: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if onKeyUp?(event) != true {
            super.keyUp(with: event)
        }
    }
}
