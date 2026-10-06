import Carbon.HIToolbox
import Cocoa

// MARK: - 数据模型

/// 组里的一个 app。
///
/// 存**路径字符串**而不是 URL：JSON 可读、可手写（配置文件要能进 dotfiles），
/// 而且不依赖 URL 的 Codable 表示。
struct AppRef: Codable, Equatable {
    var path: String
    var displayName: String

    var bundleURL: URL { URL(fileURLWithPath: path) }

    var bundleIdentifier: String? { Bundle(url: bundleURL)?.bundleIdentifier }

    /// 同一个 app 是否已在这个组里（用解析后的规范化路径比较，
    /// 免得 `/Applications/X.app` 和 `/Applications/./X.app` 被当成两个）。
    func isSameApp(as other: AppRef) -> Bool {
        bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            == other.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var icon: NSImage? {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    /// 该 app 当前是否在运行（HUD 上要用它区分「激活」与「启动」）。
    var isRunning: Bool {
        guard let id = bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }
}

/// 一个组 = 一个快捷键 + 一串**有序** app。
///
/// 顺序由用户在配置窗里拖动决定，是固定顺序，不是 MRU——
/// 这是与 GroupTab 的核心分叉，也是「按 N 次落在第 N 个」能成立的前提。
struct GroupConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// 非修饰键的 keyCode。0 表示尚未绑定。
    var keyCode: UInt16
    /// NSEvent.ModifierFlags 的 rawValue，只保留设备无关的位。
    var modifiers: UInt
    var apps: [AppRef] = []

    // MARK: 磁盘表示

    /// 落盘只写 `shortcut` 一个可手写字符串（如 `"cmd+4"`），
    /// 而不是 keyCode + modifiers 两个数字——这份 JSON 是要手写、要进 dotfiles 的。
    /// 该格式与 Thor 的 `apps.json` 同形，日后的 Thor 导入几乎不用转换。
    private enum CodingKeys: String, CodingKey {
        case id, shortcut, apps
    }

    /// v1 的旧写法：keyCode + modifiers 两个整数。
    /// 保留读取能力，这样格式升级不会让已存在的配置丢掉绑定。
    private enum LegacyCodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    init(id: UUID = UUID(), keyCode: UInt16, modifiers: NSEvent.ModifierFlags, apps: [AppRef] = []) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = Self.normalized(modifiers).rawValue
        self.apps = apps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        apps = try container.decodeIfPresent([AppRef].self, forKey: .apps) ?? []

        // 解析不出来就当未绑定，而不是让整个文件读失败——
        // 一个手写错的组合键不该毁掉全部配置。
        let raw = try container.decodeIfPresent(String.self, forKey: .shortcut) ?? ""
        if let parsed = ShortcutCodec.parse(raw) {
            keyCode = parsed.keyCode
            modifiers = parsed.modifiers.rawValue
        } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self),
                  legacy.contains(.keyCode) {
            // 旧格式回退：读得出来就继续用，下次落盘自动写成新格式。
            keyCode = (try? legacy.decode(UInt16.self, forKey: .keyCode)) ?? 0
            modifiers = (try? legacy.decode(UInt.self, forKey: .modifiers)) ?? 0
        } else {
            keyCode = 0
            modifiers = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(apps, forKey: .apps)
        try container.encode(ShortcutCodec.string(keyCode: keyCode, modifiers: modifierFlags) ?? "",
                             forKey: .shortcut)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// 只保留设备无关修饰键（滤掉 fn、数字键盘左右等）。
    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
    }

    /// 至少一个「真」修饰键才允许绑成组热键——否则会把裸键吞掉。
    var hasRequiredModifier: Bool {
        !modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    /// 例如 "⌘4" / "⌃⌥K"。
    var shortcutLabel: String { KeyLabel.describe(keyCode: keyCode, modifiers: modifierFlags) }
}

/// 落盘的顶层结构。带 schemaVersion：以后改结构时有迁移的抓手。
struct ChordConfig: Codable {
    var schemaVersion: Int = 1
    var groups: [GroupConfig] = []
}

// MARK: - 按键显示名

enum KeyLabel {

    /// 用当前键盘布局把 keyCode 翻成可显示字符，而不是手写一张 keycode 表。
    /// 好处：任何布局（Dvorak、法语 AZERTY…）都自动正确。
    static func character(for keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "key\(keyCode)" }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return "key\(keyCode)"
            }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout,
                                        keyCode,
                                        UInt16(kUCKeyActionDisplay),
                                        0,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        characters.count,
                                        &length,
                                        &characters)
            guard status == noErr, length > 0 else { return "key\(keyCode)" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }

    /// 修饰键用符号表示，顺序按 macOS 惯例 ⌃⌥⇧⌘。
    /// 键名走 `ShortcutCodec.displayName`，而不是直接用布局字符——
    /// 后者的空格键是"一个不可见的空格"，会让标签看起来缺了键。
    static func describe(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        guard keyCode != 0 else { return text }
        return text + ShortcutCodec.displayName(for: keyCode)
    }
}

// MARK: - 持久化

/// 配置的读写。真相是磁盘上那一份 JSON，内存里的 `groups` 只是它的镜像。
final class ConfigStore {

    static let shared = ConfigStore()

    private(set) var groups: [GroupConfig] = []

    /// 每次变更后回调，供 UI 刷新与热键重注册。
    var onChange: (() -> Void)?

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Chord", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("groups.json")
    }

    // MARK: 读写

    /// 上次加载失败时，坏文件被备份到哪里（供 UI 告知用户）。
    private(set) var loadFailureBackupURL: URL?

    func load() {
        loadFailureBackupURL = nil
        guard let data = try? Data(contentsOf: fileURL) else {
            groups = []                     // 文件不存在 = 全新安装，正常路径
            return
        }
        do {
            // 磁盘上的顺序不一定是排好的（比如手写的 JSON），读进来就归一化
            groups = Self.ordered(try JSONDecoder().decode(ChordConfig.self, from: data).groups)
        } catch {
            // 解析失败时只"保留原文件"是不够的：用户下一次任何改动都会写回同一个路径，
            // 把那份还能手工抢救的内容覆盖掉。所以先**备份走**，再清空内存。
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).broken-\(stamp)")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            loadFailureBackupURL = backup
            NSLog("Chord: 配置解析失败，原文件已备份到 \(backup.path) —— \(error)")
            groups = []
        }
    }

    @discardableResult
    func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(ChordConfig(groups: groups))
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("Chord: 配置写入失败：\(error)")
            return false
        }
    }

    private func commit() {
        groups = Self.ordered(groups)
        save()
        onChange?()
    }

    // MARK: 顺序

    /// 组的排列顺序 = **快捷键的自然顺序**，而不是添加顺序。
    ///
    /// 组本身没有手排顺序（那样会让同一个列表里出现两层拖动语义，见需求池里
    /// 「组排序」那条 🚫），所以顺序是一个派生值：
    ///   已绑定在前、未绑定最后 → 修饰键少的在前 → 同修饰键内按键排。
    ///
    /// 为什么**先按修饰键分组**而不是先按键：否则 `⌥⌘1` 会插在 `⌘1` 与 `⌘2` 之间，
    /// 把 `⌘1..⌘5` 的连续性打断（第一版就是先按键，实测如此）。
    ///
    /// 放在 store 里而不是视图里，是为了让**表格行号始终等于数组下标**，
    /// 各处回调（录制、拖动、增删）都不必再维护一层映射。
    static func ordered(_ groups: [GroupConfig]) -> [GroupConfig] {
        groups.enumerated().sorted { lhs, rhs in
            let l = sortKey(lhs.element), r = sortKey(rhs.element)
            if l != r { return l.lexicographicallyPrecedes(r) }
            // 完全并列时按原下标，保证顺序确定（sorted 不保证稳定）
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 排序键：[是否未绑定, 修饰键个数, 修饰键序, 键类别, 键序号, 原 keyCode]
    private static func sortKey(_ group: GroupConfig) -> [Int] {
        guard group.hasRequiredModifier else { return [1, 0, 0, 0, 0, 0] }

        let flags = group.modifierFlags
        let modifierCount = flags.intersection([.command, .option, .control, .shift])
            .rawValue.nonzeroBitCount
        let modifierRank = modifierOrder(flags)

        let name = ShortcutCodec.keyName(for: group.keyCode)
        var keyClass = 2
        var keyOrder = 0
        if name.count == 1, let value = Int(name) {
            keyClass = 0
            // 按**键盘阅读顺序**：0 排在 9 之后（不是数值上的 0）
            keyOrder = value == 0 ? 10 : value
        } else if name.count == 1, let scalar = name.first, scalar.isLetter {
            keyClass = 1
            keyOrder = Int(scalar.asciiValue ?? 0)
        }
        return [0, modifierCount, modifierRank, keyClass, keyOrder, Int(group.keyCode)]
    }

    /// 修饰键的定序权重（⌃⌥⇧⌘ 顺序组合成一个整数），用于修饰键个数相同时定序。
    private static func modifierOrder(_ flags: NSEvent.ModifierFlags) -> Int {
        var order = 0
        if flags.contains(.command) { order |= 1 }
        if flags.contains(.shift) { order |= 2 }
        if flags.contains(.option) { order |= 4 }
        if flags.contains(.control) { order |= 8 }
        return order
    }

    // MARK: 变更

    /// 新建一个空组。keyCode/modifiers 留空，等用户录制。
    @discardableResult
    func addGroup(keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> GroupConfig {
        let group = GroupConfig(keyCode: keyCode, modifiers: modifiers)
        groups.append(group)
        commit()
        return group
    }

    func removeGroup(at index: Int) {
        guard groups.indices.contains(index) else { return }
        groups.remove(at: index)
        commit()
    }

    func removeGroup(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        removeGroup(at: index)
    }

    func setShortcut(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, groupAt index: Int) {
        guard groups.indices.contains(index) else { return }
        groups[index].keyCode = keyCode
        groups[index].modifiers = GroupConfig.normalized(modifiers).rawValue
        commit()
    }

    /// 按 id 改快捷键。重排会让下标失效，所以交换这类连续操作要用 id 定位。
    func setShortcut(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        setShortcut(keyCode, modifiers: modifiers, groupAt: index)
    }

    /// 清除绑定，把组变回"未绑定"。组本身和它的 app 都留着。
    func clearShortcut(groupAt index: Int) {
        guard groups.indices.contains(index) else { return }
        groups[index].keyCode = 0
        groups[index].modifiers = 0
        commit()
    }

    /// 追加一个 app。同一个组里已存在则拒绝（返回 false）。
    @discardableResult
    func appendApp(_ app: AppRef, groupAt index: Int) -> Bool {
        guard groups.indices.contains(index) else { return false }
        guard !groups[index].apps.contains(where: { $0.isSameApp(as: app) }) else { return false }
        groups[index].apps.append(app)
        commit()
        return true
    }

    func removeApp(groupAt index: Int, appAt appIndex: Int) {
        guard groups.indices.contains(index), groups[index].apps.indices.contains(appIndex) else { return }
        groups[index].apps.remove(at: appIndex)
        commit()
    }

    /// 组内移动（拖动排序）。
    func moveAppWithinGroup(_ groupIndex: Int, from: Int, to: Int) {
        guard groups.indices.contains(groupIndex) else { return }
        var apps = groups[groupIndex].apps
        guard apps.indices.contains(from) else { return }
        let app = apps.remove(at: from)
        let target = max(0, min(apps.count, to > from ? to - 1 : to))
        apps.insert(app, at: target)
        groups[groupIndex].apps = apps
        commit()
    }

    /// 跨组移动（拖到别的行），插入到目标组的 `to` 位置。
    ///
    /// ⚠️ 两套插入下标约定**不同**，别互相套用：
    ///   · **组内**移动的 `to` 是「含被拖项」的原数组下标——拖动期间被拖的那个 chip
    ///     还挂在条上，所以 `moveAppWithinGroup` 必须按方向做 ±1 修正；
    ///   · **跨组**的 `to` 是「目标组当前数组」的下标——目标条里从来没有被拖项，
    ///     直接用，不需要修正。
    ///
    /// 以前这里一律 `append`（落到末尾），于是拖动时画的插入线在跨行场景下是**假承诺**：
    /// 线画在你悬停的位置，东西却掉到末尾。
    func moveApp(fromGroup: Int, appAt: Int, toGroup: Int, at to: Int) {
        guard groups.indices.contains(fromGroup), groups.indices.contains(toGroup),
              groups[fromGroup].apps.indices.contains(appAt) else { return }
        let app = groups[fromGroup].apps.remove(at: appAt)
        let target = max(0, min(groups[toGroup].apps.count, to))
        groups[toGroup].apps.insert(app, at: target)
        commit()
    }

    /// 同一个 app 是否已经绑在别的组上（允许跨组重复，这里只用于提示）。
    func groupsContaining(_ app: AppRef) -> [Int] {
        groups.enumerated().compactMap { index, group in
            group.apps.contains(where: { $0.isSameApp(as: app) }) ? index : nil
        }
    }
}
