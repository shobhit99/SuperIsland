import SwiftUI

struct EmojiPickerView: View {
    @ObservedObject var manager: EmojiPickerManager
    @State private var animateIn = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(40), spacing: 8), count: manager.columns)
    }

    private var queryLabel: String {
        manager.query.isEmpty ? ":" : ":\(manager.query)"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader

            if manager.displayedResults.isEmpty {
                emptyState
            } else {
                resultsGrid
            }

            footer
        }
        .frame(width: manager.width, height: manager.panelHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: NSColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.98)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        .scaleEffect(animateIn && manager.isVisible ? 1 : 0.95, anchor: .top)
        .opacity(animateIn && manager.isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: animateIn)
        .animation(.easeOut(duration: 0.12), value: manager.isVisible)
        .onAppear {
            animateIn = true
        }
        .onChange(of: manager.isVisible) { _, visible in
            animateIn = visible
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "face.smiling")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))

            Text(queryLabel)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(manager.query.isEmpty ? 0.48 : 0.94))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05))
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)
        )
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(manager.displayedResults.enumerated()), id: \.element.id) { index, result in
                EmojiGridTile(
                    emoji: result.emoji,
                    isSelected: index == manager.selectedIndex,
                    isBouncing: manager.bouncingEmojiID == result.id
                )
                .onHover { hovering in
                    if hovering {
                        manager.hoverSelection(for: result.id)
                    }
                }
                .onTapGesture {
                    manager.commitSelection(index: index)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No emoji found")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text("Keep typing to refine the search")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            Text(manager.footerLabel ?? "Recent and common suggestions")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}

private struct EmojiGridTile: View {
    let emoji: String
    let isSelected: Bool
    let isBouncing: Bool

    var body: some View {
        Text(emoji)
            .font(.system(size: 24))
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? .white.opacity(0.14) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? .white.opacity(0.18) : .clear, lineWidth: 1)
            )
            .scaleEffect(isBouncing ? 1.12 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.45), value: isBouncing)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
