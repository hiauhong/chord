import Carbon.HIToolbox
import Cocoa

/// `--record-test`：快捷键录制的自测。
///
/// 覆盖用户提出的那个场景："按错了要能改"。两层含义都测：
///   1. 按住修饰键期间只是**待定**，不落盘 —— 所以能再按一个键替换
///   2. 目标组合已被别的组占用时，同一个组合**再按一次 = 交换**两组
///
/// 录制逻辑是纯逻辑（不吃辅助功能权限），所以可以这样直接驱动。
/// 用临时配置文件，不碰真实配置。
func runRecordTestAndExit() -> Never {
    var failures = 0
    var passed = 0
    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("✅ \(name)")
        } else {
            failures += 1
            print("❌ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("chord-record-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let store = ConfigStore(fileURL: tempURL)
    store.addGroup(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command])   // ⌘1
    store.addGroup(keyCode: UInt16(kVK_ANSI_2), modifiers: [.command])   // ⌘2
    store.addGroup(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command])   // ⌘4

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let controller = SettingsWindowController()
    controller.isHotkeyTapAvailable = { true }
    controller.store = store                                  // 换成临时配置

    func keyDown(_ code: Int, _ flags: NSEvent.ModifierFlags) -> HotkeyTap.KeyEvent {
        HotkeyTap.KeyEvent(type: .keyDown, keycode: Int64(code),
                           flags: CGEventFlags(rawValue: UInt64(flags.rawValue)), isRepeat: false)
    }
    func releaseModifiers() -> HotkeyTap.KeyEvent {
        HotkeyTap.KeyEvent(type: .flagsChanged, keycode: 55,
                           flags: CGEventFlags(rawValue: 0), isRepeat: false)
    }
    func shortcut(of id: UUID) -> String {
        guard let group = store.groups.first(where: { $0.id == id }) else { return "（组没了）" }
        return group.hasRequiredModifier ? group.shortcutLabel : "未绑定"
    }
    func id(ofShortcut label: String) -> UUID? {
        store.groups.first { $0.hasRequiredModifier && $0.shortcutLabel == label }?.id
    }

    print("Chord · 快捷键录制自测")
    print(String(repeating: "─", count: 56))
    print("初始：" + store.groups.map { $0.shortcutLabel }.joined(separator: " ") + "")
    print("")

    // 场景一：把 ⌘4 那组误按成 ⌘5，改成 ⌘3
    guard let targetID = id(ofShortcut: "⌘4") else {
        print("初始配置不对，测试无法继续。")
        exit(1)
    }
    let targetRow = store.groups.firstIndex { $0.id == targetID } ?? 0
    controller.beginRecording(row: targetRow)

    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_5, [.command]))     // 按错
    check("按下组合键后**不落盘**（还是 ⌘4）", shortcut(of: targetID) == "⌘4",
          "实际 \(shortcut(of: targetID))")

    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_3, [.command]))     // 改成 ⌘3
    check("再按一个键只是替换待定值，仍未落盘", shortcut(of: targetID) == "⌘4",
          "实际 \(shortcut(of: targetID))")

    _ = controller.consumeWhileRecording(releaseModifiers())                  // 松手 → 提交
    check("松开修饰键才提交，且提交的是最后那个（⌘3）", shortcut(of: targetID) == "⌘3",
          "实际 \(shortcut(of: targetID))")

    // 场景二：目标组合已被占用 → 再按一次交换
    let row = store.groups.firstIndex { $0.id == targetID } ?? 0
    controller.beginRecording(row: row)
    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_1, [.command]))     // ⌘1 被占
    check("撞车时第一次按不落盘、也不改别人的", shortcut(of: targetID) == "⌘3",
          "实际 \(shortcut(of: targetID))")

    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_1, [.command]))     // 再按一次 = 交换
    check("同一个组合再按一次 = 交换（本组拿到 ⌘1）", shortcut(of: targetID) == "⌘1",
          "实际 \(shortcut(of: targetID))")
    check("对方拿到原来的 ⌘3",
          store.groups.contains { $0.shortcutLabel == "⌘3" },
          "现在的组合：" + store.groups.map { $0.shortcutLabel }.joined(separator: " "))

    // 场景三：只按 Shift 不算修饰键
    let row2 = store.groups.firstIndex { $0.id == targetID } ?? 0
    controller.beginRecording(row: row2)
    let before = shortcut(of: targetID)
    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_7, [.shift]))
    check("只按 Shift 不生效，值不变", shortcut(of: targetID) == before,
          "实际 \(shortcut(of: targetID))")
    _ = controller.consumeWhileRecording(releaseModifiers())
    check("没有待定值时松手不算提交，仍在录制中", controller.recordingRow != nil)

    // 场景四：Esc 取消录制，不落盘
    let row3 = store.groups.firstIndex { $0.id == targetID } ?? 0
    controller.beginRecording(row: row3)
    let beforeEsc = shortcut(of: targetID)
    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_8, [.command]))
    _ = controller.consumeWhileRecording(keyDown(kVK_Escape, [.command]))
    check("Esc 取消后不落盘", shortcut(of: targetID) == beforeEsc,
          "实际 \(shortcut(of: targetID))")

    // 场景五：快捷键列按"配置里最宽的那个快捷键"自适应
    // 全是 ⌘N 时列窄；录进一个三键的 ⌥⌘4，列和窗口最小宽度都要跟着长。
    let narrowColumn = controller.shortcutColumnWidth
    let narrowMin = controller.window?.minSize.width ?? 0
    let row4 = store.groups.firstIndex { $0.id == targetID } ?? 0
    controller.beginRecording(row: row4)
    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_4, [.option, .command]))
    _ = controller.consumeWhileRecording(releaseModifiers())                  // 松手 → 提交
    let wideColumn = controller.shortcutColumnWidth
    let wideMin = controller.window?.minSize.width ?? 0
    check("录进 ⌥⌘4 后快捷键列变宽", wideColumn > narrowColumn,
          "\(narrowColumn) → \(wideColumn)")
    check("列宽不超过上限 124", wideColumn <= 124, "实际 \(wideColumn)")
    check("列变宽时窗口最小宽度跟着变（APP 列不让位）", wideMin > narrowMin,
          "\(narrowMin) → \(wideMin)")

    // 场景六：APP 列同样按内容自适应 —— 某个组多到 4 个 app 时，列和窗口最小宽度都要长。
    // （3 个以内是列的下限，见 appsColumnWidth 的说明，所以这里要加到 4 个。）
    let narrowApps = controller.appsColumnWidth
    let narrowAppsMin = controller.window?.minSize.width ?? 0
    // 用 4 个**不同**的 app：appendApp 会拒重复（同一条会被 ignore），拿同一个塞 4 次只算 1 个
    for index in 1...4 {
        _ = store.appendApp(AppRef(path: "/Applications/ChordTest\(index).app",
                                   displayName: "测试\(index)"),
                            groupAt: 0)
    }
    let wideApps = controller.appsColumnWidth
    let wideAppsMin = controller.window?.minSize.width ?? 0
    check("加到 4 个 app 后 APP 列变宽", wideApps > narrowApps, "\(narrowApps) → \(wideApps)")
    check("APP 列变宽时窗口最小宽度跟着变", wideAppsMin > narrowAppsMin,
          "\(narrowAppsMin) → \(wideAppsMin)")

    // 场景七：**关窗必须结束录制**。
    //
    // 录制态会把每个 keyDown/keyUp/修饰键变化都全局吞掉，而它原先只有
    // Esc / 松手提交 / 撞车交换三条出口 —— 点完录制按钮直接关窗，录制态就永远留着，
    // 整机键盘像死了（2026-09-30 真踩到）。这条用例钉的就是那个出口。
    controller.beginRecording(row: 0)
    check("关窗前处于录制中", controller.recordingRow != nil)
    let beforeClose = store.groups[0].shortcutLabel
    _ = controller.consumeWhileRecording(keyDown(kVK_ANSI_9, [.command]))    // 只按下，不松手
    controller.close()
    check("关窗后录制态清空", controller.recordingRow == nil)
    check("关窗后按键不再被吞",
          !controller.consumeWhileRecording(keyDown(kVK_ANSI_9, [.command])))

    // 残留的待定值不能漏到下一次录制里：重开录制、直接来一发"松手"，
    // 若 pendingShortcut 没被清掉，它会把这个没按完的组合提交进新行。
    controller.beginRecording(row: 0)
    _ = controller.consumeWhileRecording(releaseModifiers())
    check("重开录制时旧待定值不会被提交", store.groups[0].shortcutLabel == beforeClose,
          "期望 \(beforeClose)，实际 \(store.groups[0].shortcutLabel)")

    print("")
    print("最终：" + store.groups.map { $0.shortcutLabel }.joined(separator: " "))
    print(failures == 0 ? "全部通过：\(passed) 项" : "有 \(failures) 项未通过（通过 \(passed) 项）")
    exit(failures == 0 ? 0 : 1)
}
