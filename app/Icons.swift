// Lucide icons (https://lucide.dev, ISC licence; see lucide/LICENSE), bundled as SVGs in
// Contents/Resources/lucide and drawn as template images so they take the current colour.
import SwiftUI
import AppKit

enum Lucide {
    private static var cache: [String: NSImage] = [:]

    /// The icon as a template NSImage at `size` points (nil if it isn't bundled).
    static func nsImage(_ name: String, size: CGFloat = 16) -> NSImage? {
        let key = "\(name)@\(size)"
        if let img = cache[key] { return img }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "lucide"),
              let src = NSImage(contentsOf: url) else { return nil }
        let img = src.copy() as! NSImage
        img.size = NSSize(width: size, height: size)
        img.isTemplate = true
        img.accessibilityDescription = name
        cache[key] = img
        return img
    }

    /// The icon as a SwiftUI Image (works in tab items, menus and the menu bar).
    static func image(_ name: String, size: CGFloat = 16) -> Image {
        if let ns = nsImage(name, size: size) { return Image(nsImage: ns).renderingMode(.template) }
        return Image(systemName: "questionmark.square.dashed")
    }
}

/// A Lucide icon sized for inline use; colour comes from foregroundStyle / tint.
struct LucideIcon: View {
    let name: String
    var size: CGFloat = 15
    nonisolated init(_ name: String, size: CGFloat = 15) { self.name = name; self.size = size }
    var body: some View {
        Lucide.image(name, size: size)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Label where Title == Text, Icon == LucideIcon {
    /// Label("Check", lucide: "search"): a literal title is localized, like SwiftUI's own Label.
    init(_ title: LocalizedStringKey, lucide: String, size: CGFloat = 15) {
        self.init { Text(title) } icon: { LucideIcon(lucide, size: size) }
    }
    /// A title that's already a String (e.g. from String(localized:)) is shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, lucide: String, size: CGFloat = 15) {
        self.init { Text(title) } icon: { LucideIcon(lucide, size: size) }
    }
}
