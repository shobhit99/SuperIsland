import SwiftUI

struct AlbumArtView: View {
    let image: NSImage?
    var size: CGFloat = 56
    var cornerRadius: CGFloat? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.15, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}
