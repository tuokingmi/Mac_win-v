import AppKit
import SwiftUI

struct ClipboardImageThumbnailView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct ClipboardRowView: View {
    let item: ClipboardItem
    let thumbnailImage: NSImage?
    let isFocused: Bool
    let isMultiSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClipboardImageThumbnailView(image: thumbnailImage)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                }

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isMultiSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(isMultiSelected ? 0.8 : 0.45), lineWidth: 1)
            }
        }
    }

    private var backgroundStyle: some ShapeStyle {
        if isMultiSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }

        if isFocused {
            return AnyShapeStyle(Color.accentColor.opacity(0.08))
        }

        return AnyShapeStyle(Color.white.opacity(0.04))
    }

    private var title: String {
        switch item.kind {
        case .text:
            return item.displayTitle
        case .image:
            return "Image"
        }
    }

    private var subtitle: String {
        switch item.kind {
        case .text:
            return item.createdAt.formatted(.dateTime.hour().minute())
        case .image:
            let width = Int(item.imageWidth ?? 0)
            let height = Int(item.imageHeight ?? 0)
            return "\(width)×\(height)  ·  \(item.createdAt.formatted(.dateTime.hour().minute()))"
        }
    }
}
