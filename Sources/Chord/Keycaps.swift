import Cocoa

/// 把快捷键画成一排键帽（`⌘` `1`），配置窗和切换浮层共用。
///
/// 为什么不直接显示 "⌘1" 这串文字：键帽一眼就读成「按这几个键」，
/// 文字则要先读再解析；而且修饰键和主键分开后，⌥⌘F12 这类长组合也不会糊成一团。
enum Keycaps {

    private static let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    /// "⌥⌘F12" → ["⌥", "⌘", "F12"]。修饰键一个一帽，其余整体是主键。
    static func tokens(of label: String) -> [String] {
        var tokens: [String] = []
        var rest = Substring(label)
        while let first = rest.first, modifierGlyphs.contains(first) {
            tokens.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { tokens.append(String(rest)) }
        return tokens
    }

    struct Style {
        var fontSize: CGFloat = 12
        var height: CGFloat = 22
        var spacing: CGFloat = 3
        /// 文字两侧合计留白（键帽宽 = max(高, 文字宽 + 留白)）
        var padding: CGFloat = 12
        /// nil = 常规配色；给了颜色就整排染成这个色（录制中的待定组合用橙色）。
        var tint: NSColor? = nil
        /// 键帽底的浓度。**按背景明暗分开给**：配置窗是浅色底，键帽底要淡
        /// （0.10/0.22 那版渲出来量到 #C0，一排就是几块明显的深灰方块）；
        /// 切换浮层是深色底，得浓一点才看得出键帽的形状，否则只剩字形浮在那儿。
        var faceAlpha: CGFloat = 0.05
        var edgeAlpha: CGFloat = 0.12

        var font: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    }

    static func size(of tokens: [String], style: Style) -> NSSize {
        let widths = tokens.map { capWidth($0, style: style) }
        let total = widths.reduce(0, +) + style.spacing * CGFloat(max(0, tokens.count - 1))
        return NSSize(width: total, height: style.height + 1)   // +1 = 键帽底边的"厚度"
    }

    /// 在 `origin`（左下角，非翻转坐标）开始画一排键帽。
    static func draw(_ tokens: [String], at origin: NSPoint, style: Style) {
        let textColor = style.tint ?? .labelColor
        let face = (style.tint ?? .labelColor).withAlphaComponent(style.tint == nil ? style.faceAlpha : 0.16)
        let edge = (style.tint ?? .labelColor).withAlphaComponent(style.tint == nil ? style.edgeAlpha : 0.35)
        let attributes: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: textColor]

        var x = origin.x
        for token in tokens {
            let width = capWidth(token, style: style)
            let cap = NSRect(x: x, y: origin.y + 1, width: width, height: style.height)
            // 先画一个下移 1pt 的底，再盖面：露出的那一条就是键帽的厚度
            edge.setFill()
            NSBezierPath(roundedRect: cap.offsetBy(dx: 0, dy: -1), xRadius: 5, yRadius: 5).fill()
            face.setFill()
            NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5).fill()

            let text = NSAttributedString(string: token, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: cap.midX - textSize.width / 2,
                                  y: cap.midY - textSize.height / 2))
            x += width + style.spacing
        }
    }

    private static func capWidth(_ token: String, style: Style) -> CGFloat {
        let textWidth = NSAttributedString(string: token, attributes: [.font: style.font]).size().width
        // 单字符键帽是正方形；F12、Space 这类按文字宽度撑开
        return max(style.height, ceil(textWidth) + style.padding)
    }
}

/// 一排键帽作为独立视图（浮层顶部显示当前组的快捷键）。
final class KeycapsView: NSView {

    var tokens: [String] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var style = Keycaps.Style() {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { Keycaps.size(of: tokens, style: style) }

    override func draw(_ dirtyRect: NSRect) {
        Keycaps.draw(tokens, at: .zero, style: style)
    }
}
