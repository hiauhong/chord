import Cocoa

/// `--drag-mouse-test`：拖动**起手**的合成事件自测。
///
/// 为什么单独有这一项：`--drag-test` 只验证「落点算得对不对」和「移动后的顺序对不对」，
/// 它自己那句注释——"真实的鼠标拖动我模拟不了"——曾经放过去一个致命 bug：
/// `AppChipView` 没重写 `mouseDown`，点击沿响应链冒泡到外层 `NSTableView`，
/// 表格进入自己的选择跟踪循环，把后续 `mouseDragged` 全吃掉。
/// 于是**图标根本拖不动**，落点算得再对也没用。
///
/// 所以这里断言的重点不是"拖完落到哪"，而是**手势归谁**：
/// 按在 chip 上时，mouseDown 不许冒泡到表格。
///
/// 手段是 `NSApp.postEvent` 合成鼠标事件：不动真实光标、不需要辅助功能权限。
/// 代价是事件派发要求窗口是 key，所以它会**短暂把本进程激活一次**
/// （窗口只在测试期间出现，跑完立刻 orderOut）。
final class DragSpyTableView: NSTableView {
    /// 表格自己收到几次 mouseDown。正常应当恒为 0：chip 必须把手势止在自己这里。
    var mouseDownCount = 0
    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
        super.mouseDown(with: event)
    }
}

private final class OneRowDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let cell: AppsCellView
    init(cell: AppsCellView) { self.cell = cell }
    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { cell }
}

func runDragMouseTestAndExit() -> Never {
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

    print("Chord · 拖动起手自测（合成鼠标事件）")
    print(String(repeating: "─", count: 56))

    // 真的需要 3 个本机 app 才能搭出图标条（和 --drag-test 用同一份候选）
    let candidates = ["/Applications/Google Chrome.app",
                      "/Applications/Safari.app",
                      "/System/Applications/Notes.app",
                      "/System/Applications/Calculator.app"]
    let apps = candidates.filter { FileManager.default.fileExists(atPath: $0) }.prefix(3).map {
        AppRef(path: $0, displayName: FileManager.default.displayName(atPath: $0)
            .replacingOccurrences(of: ".app", with: ""))
    }
    guard apps.count == 3 else {
        print("需要 3 个真实 app 才能搭出图标条，只找到 \(apps.count) 个。")
        exit(1)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // 合成事件只有在 **key window** 上才会被正常派发。探针里踩过这个坑：
    // 窗口不是 key 时事件根本到不了视图，断言全是假通过/假失败。
    // 代价是本进程会短暂被激活一次（窗口跑完立刻 orderOut）。
    app.activate(ignoringOtherApps: true)

    // 层级照抄真实配置窗：
    // window.contentView → NSScrollView → NSTableView → NSTableRowView → AppsCellView → chip
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
    let table = DragSpyTableView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
    table.rowHeight = 60
    table.headerView = nil

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("apps"))
    column.width = 400
    table.addTableColumn(column)

    let cell = AppsCellView()
    cell.configure(group: GroupConfig(keyCode: 19, modifiers: [.command], apps: apps),
                   onAddApp: {}, onRemoveApp: { _ in })
    let source = OneRowDataSource(cell: cell)
    table.dataSource = source
    table.delegate = source

    let scroll = NSScrollView(frame: container.bounds)
    scroll.documentView = table
    container.addSubview(scroll)
    window.contentView = container
    window.makeKeyAndOrderFront(nil)
    table.reloadData()
    table.layoutSubtreeIfNeeded()
    cell.layoutSubtreeIfNeeded()

    guard let chip = cell.strip.arrangedSubviews.compactMap({ $0 as? AppChipView }).dropFirst().first else {
        print("图标条里没有第 2 个 chip，搭台失败。")
        exit(1)
    }

    var eventNumber = 1
    func post(_ type: NSEvent.EventType, at point: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: type,
                                             location: point,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: eventNumber,
                                             clickCount: 1,
                                             pressure: 1) else { return }
        eventNumber += 1
        NSApp.postEvent(event, atStart: false)
    }

    /// 等价于 `NSApp.run` 的最小事件泵：把队列里的事件取出来派发掉。
    func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any,
                                           until: Date().addingTimeInterval(0.02),
                                           inMode: .default,
                                           dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    func downEvent(at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDown,
                           location: point,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber,
                           context: nil,
                           eventNumber: 90_000,
                           clickCount: 1,
                           pressure: 1)
    }

    // 前提检查放前面：窗口不是 key 的话，下面每一条断言都没有意义，
    // 与其报一堆假失败，不如直接说清楚。
    let chipCenter = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
    pump(0.2)
    guard window.isKeyWindow else {
        print("⚠️ 拿不到 key window（appActive=\(NSApp.isActive)），合成事件不会被派发，本项无法验证。")
        print("   在没有窗口会话的环境（ssh / CI）跑会这样，属于预期。")
        window.orderOut(nil)
        exit(2)
    }
    check("窗口是 key（合成事件才会被派发）", true)
    check("命中的是 chip 自己（不是表格、也不是图标那层 NSImageView）",
          container.hitTest(chipCenter) is AppChipView,
          "命中 \(String(describing: container.hitTest(chipCenter)))")

    // 1. 手势归属：按在图标上，mouseDown 不许冒泡到表格
    table.deselectAll(nil)
    table.mouseDownCount = 0
    post(.leftMouseDown, at: chipCenter)
    post(.leftMouseUp, at: chipCenter)
    pump(0.5)
    check("按在图标上时 mouseDown 不冒泡到外层表格（拖动起手的前提）",
          table.mouseDownCount == 0,
          "表格收到了 \(table.mouseDownCount) 次 mouseDown —— 说明响应链又在往上交，拖动会被表格的跟踪循环吃掉")
    check("点图标仍然选中它所在的行（选中行为没被这次改动弄丢）",
          table.selectedRow == 0, "selectedRow=\(table.selectedRow)")

    // 2. 起手阈值：抖动不算拖动，动了才算
    if let down = downEvent(at: chipCenter) {
        post(.leftMouseDragged, at: NSPoint(x: chipCenter.x + 1, y: chipCenter.y))
        post(.leftMouseUp, at: NSPoint(x: chipCenter.x + 1, y: chipCenter.y))
        check("移动 1pt 算点击、不起手拖动（阈值 3pt）",
              chip.dragEventStartingAt(down) == nil, "却起了手")

        post(.leftMouseDragged, at: NSPoint(x: chipCenter.x + 40, y: chipCenter.y))
        check("移动 40pt 起手拖动",
              chip.dragEventStartingAt(down) != nil, "没有起手")
    } else {
        check("能造出合成按下事件", false, "NSEvent.mouseEvent 返回 nil")
    }

    // 3. 落点链路本身仍然完好（拖动真起来了才用得上，这里顺手回归一次）
    var drops: [(group: UUID, index: Int, insert: Int)] = []
    cell.strip.onDrop = { drops.append(($0, $1, $2)) }
    let groupID = UUID()
    let chipFrames = cell.strip.arrangedSubviews.map { cell.strip.convert($0.bounds, from: $0) }
    _ = cell.strip.handleDrop(payload: AppDragPayload(groupID: groupID, index: 0),
                              at: NSPoint(x: chipFrames[2].maxX + 100, y: 20))
    check("落下仍然报出插入下标（拖到最右 → 3）",
          drops.last?.insert == 3, "拿到 \(String(describing: drops.last?.insert))")

    window.orderOut(nil)

    print("")
    print(failures == 0 ? "全部通过：\(passed) 项" : "有 \(failures) 项未通过（通过 \(passed) 项）")
    exit(failures == 0 ? 0 : 1)
}
