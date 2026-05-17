import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfCompactView: View {
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: shelf.items.isEmpty ? "tray" : "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            if let latest = latestItem {
                Text(latest.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Text("Shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }

            if !shelf.items.isEmpty {
                Text("\(shelf.items.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }
        }
    }

    private var latestItem: ShelfItem? {
        shelf.items.sorted { $0.addedAt > $1.addedAt }.first
    }
}

struct ShelfExpandedView: View {
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Shelf", systemImage: "tray.full.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text(shelf.items.isEmpty ? "Drop files, links, images, or text" : "\(shelf.items.count) saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }

            if shelf.items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.78))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop onto the island")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Items stay here until you remove them.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(previewItems) { item in
                            ExpandedShelfChip(item: item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var previewItems: [ShelfItem] {
        Array(shelf.items.sorted { $0.addedAt > $1.addedAt }.prefix(4))
    }
}

struct ShelfFullExpandedView: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 12) {
            AirDropDropPane()
                .frame(width: 142)

            TrayDropPane(
                items: filteredItems,
                totalCount: orderedItems.count,
                isFiltering: !trimmedSearchText.isEmpty,
                searchText: $searchText
            )
                .environmentObject(appState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var orderedItems: [ShelfItem] {
        shelf.items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            return lhs.addedAt > rhs.addedAt
        }
    }

    private var filteredItems: [ShelfItem] {
        let query = trimmedSearchText.lowercased()
        guard !query.isEmpty else { return orderedItems }
        return orderedItems.filter { item in
            item.displayName.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
                || (item.previewText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AirDropDropPane: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var isTargeted = false

    var body: some View {
        Button {
            shelf.openAirDropPicker()
        } label: {
            VStack(spacing: 10) {
                Circle()
                    .fill(Color.white.opacity(isTargeted ? 0.12 : 0.08))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "airplayaudio")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(isTargeted ? 0.96 : 0.84))
                    }

                Text("AirDrop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Drop to share")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panelBackground)
            .overlay(panelStroke)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $isTargeted) { providers in
            shelf.handleAirDropDrop(providers: providers)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.03))
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(
                isTargeted ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.12),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8])
            )
    }
}

private struct TrayDropPane: View {
    let items: [ShelfItem]
    let totalCount: Int
    let isFiltering: Bool
    @Binding var searchText: String

    @ObservedObject private var shelf = ShelfStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var isTargeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            isTargeted ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8])
                        )
                )

            if totalCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))

                    Text("Drop files here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Shelf")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))

                        Text(totalCount == 1 ? "1 item" : "\(totalCount) items")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))

                        Spacer(minLength: 8)

                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(width: 150)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )

                        Menu("Clear") {
                            Button("Clear Unpinned") {
                                shelf.clearUnpinned()
                            }
                            .disabled(!shelf.items.contains { !$0.isPinned })

                            Button("Clear All") {
                                shelf.clear()
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .hoverPointer()
                    }

                    if items.isEmpty && isFiltering {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.64))
                            Text("No matches")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0)

                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 18) {
                                    ForEach(items) { item in
                                        TrayItemTile(item: item)
                                            .id(item.id)
                                    }
                                }
                                .padding(.horizontal, 4)
                                .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 88)
                            .onAppear {
                                scrollToLatest(using: proxy, animated: false)
                            }
                            .onChange(of: items.count) { _, _ in
                                scrollToLatest(using: proxy, animated: true)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                }
                .padding(14)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $isTargeted) { providers in
            shelf.handleDrop(providers: providers) { addedCount in
                guard addedCount > 0 else { return }
                appState.presentShelfAfterDrop()
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = items.first?.id else { return }
        if animated {
            withAnimation(.smooth(duration: 0.22)) {
                proxy.scrollTo(lastID, anchor: .leading)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .leading)
        }
    }
}

private struct ExpandedShelfChip: View {
    let item: ShelfItem
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        Button {
            shelf.open(item)
        } label: {
            HStack(spacing: 8) {
                ShelfItemArtworkView(item: item, size: 24, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 164, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .onDrag {
            shelf.dragProvider(for: item)
        }
        .contextMenu {
            ShelfItemActionsMenu(item: item)
        }
    }
}

private struct TrayItemTile: View {
    let item: ShelfItem
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ShelfItemArtworkView(item: item, size: 42, cornerRadius: 9)

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 15, height: 15)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.28))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )
                        .offset(x: -34, y: -4)
                }

                if item.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.yellow.opacity(0.95))
                        .frame(width: 15, height: 15)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.28))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )
                        .offset(x: -17, y: -4)
                }

                Button {
                    shelf.remove(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 15, height: 15)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.28))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )
                        .shadow(color: .white.opacity(0.08), radius: 6)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .opacity(isHovering ? 1 : 0.82)
            }

            VStack(spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 104)

                Text(item.subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                    .frame(width: 104)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 116, height: 82, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            shelf.open(item)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onDrag {
            shelf.dragProvider(for: item)
        }
        .contextMenu {
            ShelfItemActionsMenu(item: item)
        }
    }
}

private struct ShelfItemActionsMenu: View {
    let item: ShelfItem
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        Button(item.isPinned ? "Unpin" : "Pin") {
            shelf.togglePinned(item)
        }

        if !item.isMissing {
            Button("Open") {
                shelf.open(item)
            }
        }

        if item.canQuickLook {
            Button("Quick Look") {
                shelf.quickLook(item)
            }
        }

        if item.isFileBacked && !item.isMissing {
            Button("Show in Finder") {
                shelf.reveal(item)
            }
        }

        Divider()

        if !item.isMissing || !item.isFileBacked {
            Button(copyTitle) {
                shelf.copy(item)
            }
        }

        if item.isFileBacked {
            Button("Copy Path") {
                shelf.copyPath(item)
            }
        }

        if !item.isMissing || !item.isFileBacked {
            Divider()

            Button("Share...") {
                shelf.share(items: [item])
            }

            Button("Share via AirDrop") {
                shelf.shareViaAirDrop(items: [item])
            }
        }

        Divider()

        Button("Remove") {
            shelf.remove(item)
        }
    }

    private var copyTitle: String {
        switch item.kind {
        case .link: return "Copy Link"
        case .text: return "Copy Text"
        default: return "Copy Item"
        }
    }
}

private struct ShelfItemArtworkView: View {
    let item: ShelfItem
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var previewImage: NSImage?

    var body: some View {
        Group {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(item.isFileBacked ? 0 : 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: item.id) {
            previewImage = await ShelfThumbnailLoader.thumbnail(for: item, size: size)
        }
    }
}

@MainActor
private enum ShelfThumbnailLoader {
    static func thumbnail(for item: ShelfItem, size: CGFloat) async -> NSImage? {
        guard item.isFileBacked, !item.isMissing, let url = item.resolvedFileURL else {
            return nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}
