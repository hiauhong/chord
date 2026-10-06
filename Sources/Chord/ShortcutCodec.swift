import Carbon.HIToolbox
import Cocoa

/// 快捷键的**磁盘表示**：可手写的字符串，例如 `"cmd+4"` / `"ctrl+alt+k"` / `"cmd+space"`。
///
/// 为什么不直接落 keyCode + modifiers 两个数字：那份 JSON 是人要手写、要进 dotfiles 的，
/// `"modifiers": 1048576` 这种东西没法手写。顺带一个好处是这个格式与
/// Thor 的 `apps.json` 里的 `shortcut` 字段同形，以后的 Thor 导入几乎不用转换。
///
/// 解析对顺序不敏感（`"shift+cmd+4"` 与 `"cmd+shift+4"` 等价），
/// 输出用固定的 macOS 惯例顺序 ⌃⌥⇧⌘，所以往返是幂等的。
enum ShortcutCodec {

    /// 无对应可打印字符的键，给个名字。
    private static let namedKeys: [String: Int] = [
        "space": kVK_Space,
        "tab": kVK_Tab,
        "return": kVK_Return,
        "escape": kVK_Escape,
        "delete": kVK_Delete,
        "forwarddelete": kVK_ForwardDelete,
        "home": kVK_Home,
        "end": kVK_End,
        "pageup": kVK_PageUp,
        "pagedown": kVK_PageDown,
        "left": kVK_LeftArrow,
        "right": kVK_RightArrow,
        "up": kVK_UpArrow,
        "down": kVK_DownArrow,
        "`": kVK_ANSI_Grave,
        "-": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash,
        ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash,
    ]

    private static let modifiersByName: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "ctrl": .control, "control": .control, "⌃": .control,
        "alt": .option, "opt": .option, "option": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
    ]

    /// 可打印字符 → keyCode。**运行时按当前键盘布局生成**，所以不写死一张 keycode 表。
    private static let printableKeys: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for code in 0..<128 {
            let name = KeyLabel.character(for: UInt16(code)).lowercased()
            guard name.count == 1,
                  let scalar = name.unicodeScalars.first,
                  scalar.isASCII,
                  scalar.value > 32,          // 滤掉空格等控制字符
                  map[name] == nil else { continue }
            map[name] = UInt16(code)
        }
        return map
    }()

    /// 屏幕上给人看的名字。**和 `keyName` 是两回事**：
    /// `keyName` 要能手写、能往返（`"space"`），这里要好看（`"␣"` / `"Space"` 之类）。
    ///
    /// 分开的原因是个真实 bug：空格键的 `KeyLabel.character` 返回的是一个**不可见的空格**，
    /// 拿它当显示名会渲染成 `"⌘"`，看上去像丢了键。
    ///
    /// 另外这些符号要**运行时验覆盖**：系统 UI 字体并不含全部符号，
    /// 实测缺 ⇥(Tab) ↩(Return) ⇞(PageUp) ⇟(PageDown)——直接用会渲染成方框。
    /// 所以那几个用文字名，其余符号也过一遍 `hasGlyph` 兜底。
    private static let displayGlyphs: [Int: String] = [
        kVK_Space: "Space",
        kVK_Tab: "Tab",
        kVK_Return: "Return",
        kVK_Escape: "⎋",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "PgUp",
        kVK_PageDown: "PgDn",
    ]

    /// 这段文字在系统 UI 字体里有没有字形。没有就会渲染成方框。
    static func hasGlyph(_ text: String) -> Bool {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count)
    }

    /// 诊断用：列出缺覆盖的显示字形。`--ui-metrics` 会打印它，
    /// 这样"某个键名显示成方框"这类问题不必靠肉眼发现。
    static func missingDisplayGlyphs() -> [String] {
        displayGlyphs
            .filter { !hasGlyph($0.value) }
            .map { "\($0.value) (keyCode \($0.key))" }
            .sorted()
    }

    static func displayName(for keyCode: UInt16) -> String {
        if let glyph = displayGlyphs[Int(keyCode)] {
            // 兜底：哪天某个符号在系统字体里没了，退回可读的名字而不是方框。
            return hasGlyph(glyph) ? glyph : keyName(for: keyCode).capitalized
        }
        let character = KeyLabel.character(for: keyCode)
        if character.count == 1,
           let scalar = character.unicodeScalars.first,
           scalar.isASCII, scalar.value > 32 {
            return character.uppercased()
        }
        return keyName(for: keyCode)
    }

    /// keyCode → 字符串里那个键名。
    static func keyName(for keyCode: UInt16) -> String {
        let character = KeyLabel.character(for: keyCode)
        if character.count == 1,
           let scalar = character.lowercased().unicodeScalars.first,
           scalar.isASCII, scalar.value > 32 {
            return character.lowercased()
        }
        for (name, code) in namedKeys where UInt16(code) == keyCode { return name }
        return "key\(keyCode)"
    }

    static func keyCode(forKeyName name: String) -> UInt16? {
        let lower = name.lowercased()
        if let code = namedKeys[lower] { return UInt16(code) }
        return printableKeys[lower]
    }

    // MARK: 组合串

    /// 例如 `(.command, 21)` → `"cmd+4"`。keyCode 为 0 表示还没绑定，返回 nil。
    static func string(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard keyCode != 0 else { return nil }
        let normalized = GroupConfig.normalized(modifiers)

        var parts: [String] = []
        if normalized.contains(.control) { parts.append("ctrl") }
        if normalized.contains(.option) { parts.append("alt") }
        if normalized.contains(.shift) { parts.append("shift") }
        if normalized.contains(.command) { parts.append("cmd") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: "+")
    }

    /// 解析组合串。顺序不敏感；修饰键重复、键名不认识都返回 nil。
    static func parse(_ string: String) -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        var resolvedKeyCode: UInt16?

        for component in raw.split(separator: "+").map(String.init) {
            let token = component.trimmingCharacters(in: .whitespaces).lowercased()
            guard !token.isEmpty else { return nil }

            if let flag = modifiersByName[token] {
                guard !modifiers.contains(flag) else { return nil }   // 重复修饰键
                modifiers.insert(flag)
                continue
            }
            // 只允许一个非修饰键
            guard resolvedKeyCode == nil, let code = keyCode(forKeyName: token) else { return nil }
            resolvedKeyCode = code
        }

        guard let resolved = resolvedKeyCode else { return nil }
        return (resolved, modifiers)
    }
}
