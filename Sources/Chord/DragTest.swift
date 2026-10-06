import Cocoa

/// `--drag-test`：拖动排序的自测。
///
/// 真实的鼠标拖动我模拟不了，但**落点算得对不对**和**移动后的顺序对不对**可以断言。
/// 这两件事覆盖了拖动路径上所有会出错的地方：
///   1. 拖动载荷的编解码往返
///   2. 图标条是否注册了拖动类型（没注册就永远收不到放下事件）
///   3. 落点坐标 → 插入下标
///   4. 插入下标 → 组内新顺序（含"从前往后挪"时的下标偏移修正）
///
/// ⚠️ 这里**不覆盖**"拖动能不能起手"——那是手势归属问题，曾经真的漏过
/// （图标拖不动）。那一层在 `--drag-mouse-test` 里用合成鼠标事件断言。
func runDragTestAndExit() -> Never {
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

    print("Chord · 拖动排序自测")
    print(String(repeating: "─", count: 56))

    // 1. 载荷往返
    let groupID = UUID()
    let encoded = AppDragPayload(groupID: groupID, index: 2).stringValue
    let decoded = AppDragPayload(string: encoded)
    check("拖动载荷编解码往返", decoded?.groupID == groupID && decoded?.index == 2,
          "编码为 \(encoded)，解出 \(String(describing: decoded))")

    // 2. 拖动类型注册
    let bareStrip = AppStripView()
    check("图标条注册了 .chordApp 拖动类型",
          bareStrip.registeredDraggedTypes.contains(.chordApp),
          "已注册：\(bareStrip.registeredDraggedTypes.map(\.rawValue))")

    // 3. 落点 → 插入下标（用真实的 AppsCellView，让 chip 真的参与布局）
    let candidates = ["/Applications/Google Chrome.app",
                      "/Applications/Safari.app",
                      "/System/Applications/Notes.app",
                      "/System/Applications/Calculator.app"]
    let apps = candidates.filter { FileManager.default.fileExists(atPath: $0) }.prefix(3).map {
        AppRef(path: $0, displayName: FileManager.default.displayName(atPath: $0)
            .replacingOccurrences(of: ".app", with: ""))
    }
    guard apps.count == 3 else {
        print("需要 3 个真实 app 才能跑这项测试，只找到 \(apps.count) 个。")
        exit(1)
    }

    let cell = AppsCellView()
    cell.frame = NSRect(x: 0, y: 0, width: 340, height: 60)
    var drops: [(group: UUID, index: Int, insert: Int)] = []
    cell.configure(group: GroupConfig(keyCode: 21, modifiers: [.command], apps: apps),
                   onAddApp: {}, onRemoveApp: { _ in })
    cell.strip.onDrop = { drops.append(($0, $1, $2)) }
    cell.layoutSubtreeIfNeeded()

    func drop(atX x: CGFloat) {
        _ = cell.strip.handleDrop(payload: AppDragPayload(groupID: groupID, index: 0),
                                  at: NSPoint(x: x, y: 20))
    }

    let chipFrames = cell.strip.arrangedSubviews.map { cell.strip.convert($0.bounds, from: $0) }
    let spacing = cell.strip.spacing

    drop(atX: -50)                                  // 最左
    check("落到最左 → 插入下标 0", drops.last?.insert == 0, "拿到 \(String(describing: drops.last?.insert))")

    drop(atX: 10_000)                               // 最右
    check("落到最右 → 插入下标 = 数量 \(apps.count)",
          drops.last?.insert == apps.count, "拿到 \(String(describing: drops.last?.insert))")

    // 落在第 1、2 个 chip 之间 → 下标 1
    let betweenFirstSecond = (chipFrames[0].maxX + chipFrames[1].minX) / 2
    drop(atX: betweenFirstSecond)
    check("落在第 1、2 个之间 → 插入下标 1", drops.last?.insert == 1,
          "落点 x=\(Int(betweenFirstSecond))，拿到 \(String(describing: drops.last?.insert))")

    // 落在第 2 个 chip 的左半边 → 下标 1（因为拿 chip 的中线判定）
    drop(atX: chipFrames[1].minX + 2)
    check("落在第 2 个的左半边 → 插入下标 1", drops.last?.insert == 1,
          "拿到 \(String(describing: drops.last?.insert))")

    // 落在第 2 个 chip 的右半边 → 下标 2
    drop(atX: chipFrames[1].maxX - 2)
    check("落在第 2 个的右半边 → 插入下标 2", drops.last?.insert == 2,
          "拿到 \(String(describing: drops.last?.insert))")

    check("拖动回调带上了源组与源下标",
          drops.allSatisfy { $0.group == groupID && $0.index == 0 })

    // 4. 插入下标 → 新顺序。用**临时**配置文件，绝不碰真实配置。
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("chord-drag-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let store = ConfigStore(fileURL: tempURL)
    let a = AppRef(path: "/tmp/A.app", displayName: "A")
    let b = AppRef(path: "/tmp/B.app", displayName: "B")
    let c = AppRef(path: "/tmp/C.app", displayName: "C")
    store.addGroup(keyCode: 21, modifiers: [.command])
    for app in [a, b, c] { store.appendApp(app, groupAt: 0) }

    func order() -> String { store.groups[0].apps.map(\.displayName).joined() }

    check("初始顺序 ABC", order() == "ABC", "实际 \(order())")

    store.moveAppWithinGroup(0, from: 0, to: 3)     // A 拖到最右
    check("A 拖到最右 → BCA", order() == "BCA", "实际 \(order())")

    store.moveAppWithinGroup(0, from: 2, to: 0)     // 末尾那个拖到最左
    check("末尾拖到最左 → ABC", order() == "ABC", "实际 \(order())")

    store.moveAppWithinGroup(0, from: 0, to: 2)     // A 拖到第 2 个之前
    check("A 拖到中间（下标 2）→ BAC", order() == "BAC", "实际 \(order())")

    store.moveAppWithinGroup(0, from: 1, to: 1)     // 原地
    check("拖回原位不变", order() == "BAC", "实际 \(order())")

    // 5. 跨组移动
    store.addGroup(keyCode: 23, modifiers: [.command])
    store.moveApp(fromGroup: 0, appAt: 0, toGroup: 1, at: 0)
    check("跨组移动：源组少一个、目标组多一个",
          store.groups[0].apps.count == 2 && store.groups[1].apps.count == 1,
          "源 \(store.groups[0].apps.count) 目标 \(store.groups[1].apps.count)")

    // 落点必须用插入下标，而不是一律追加到末尾——否则拖动时画的插入线是假承诺。
    // 此刻组 0 = [A, C]，组 1 = [B]；把 C 插到组 1 的第 0 位。
    func names(_ group: Int) -> String { store.groups[group].apps.map(\.displayName).joined() }
    store.moveApp(fromGroup: 0, appAt: 1, toGroup: 1, at: 0)
    check("跨组移动落到指定下标（不是追加到末尾）", names(1) == "CB",
          "组 1 实际 \(names(1))（追加到末尾会是 BC）")

    // 超出范围要夹住，不能崩
    store.moveApp(fromGroup: 0, appAt: 0, toGroup: 1, at: 99)
    check("跨组插入下标越界时夹到末尾", names(1) == "CBA" && names(0).isEmpty,
          "组 1 实际 \(names(1))，组 0 实际 \(names(0))")

    // 6. 组按快捷键排序（列表顺序是派生值，不是添加顺序）
    do {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chord-order-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = ConfigStore(fileURL: tempURL)

        // 故意乱序添加：⌘5、⌘1、未绑定、⌘4、⌘2、⌥⌘1
        store.addGroup(keyCode: 23, modifiers: [.command])            // 5
        store.addGroup(keyCode: 18, modifiers: [.command])            // 1
        store.addGroup()                                              // 未绑定
        store.addGroup(keyCode: 21, modifiers: [.command])            // 4
        store.addGroup(keyCode: 19, modifiers: [.command])            // 2
        store.addGroup(keyCode: 18, modifiers: [.command, .option])   // ⌥⌘1

        let labels = store.groups.map { $0.hasRequiredModifier ? $0.shortcutLabel : "未绑定" }
        check("组按快捷键排序，未绑定排最后",
              labels == ["⌘1", "⌘2", "⌘4", "⌘5", "⌥⌘1", "未绑定"],
              "实际 \(labels)")

        // 改快捷键后应当重新落位
        store.setShortcut(29, modifiers: [.command], groupAt: labels.firstIndex(of: "⌘1") ?? 0)   // ⌘0
        let afterEdit = store.groups.map { $0.hasRequiredModifier ? $0.shortcutLabel : "未绑定" }
        check("改完快捷键后重新排序（⌘0 排到最后）",
              afterEdit == ["⌘2", "⌘4", "⌘5", "⌘0", "⌥⌘1", "未绑定"],
              "实际 \(afterEdit)")
    }

    print("")
    print(failures == 0 ? "全部通过：\(passed) 项" : "有 \(failures) 项未通过（通过 \(passed) 项）")
    exit(failures == 0 ? 0 : 1)
}
