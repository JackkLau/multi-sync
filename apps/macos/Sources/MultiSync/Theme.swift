import SwiftUI

enum Theme {
    static let accent = Color(red: 9/255, green: 108/255, blue: 116/255)
    static let ink = Color(red: 24/255, green: 50/255, blue: 56/255)
    static let muted = Color(red: 84/255, green: 105/255, blue: 110/255)
    static let canvas = Color(red: 244/255, green: 248/255, blue: 249/255)
    static let line = Color(red: 214/255, green: 227/255, blue: 229/255)
    static let radius: CGFloat = 14
    static let gap: CGFloat = 20
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(.white, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
    }
}

func byteCount(_ count: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(count, UInt64(Int64.max))), countStyle: .file)
}
