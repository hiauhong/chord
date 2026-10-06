import ApplicationServices
import Cocoa

/// `--state-test`：状态机的机械自测。
///
/// 理由和配置层一样：HUD 长什么样我看不见，但"按 N 次会落在哪"是可以断言的。
/// 状态机刻意不依赖事件流和 UI，就是为了能这样验。
func runStateTestAndExit() -> Never {
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

    // 假 app：路径 → 窗口数。窗口对象只需要一个存在的 AX 元素，不需要权限。
    let chrome = AppRef(path: "/Applications/Google Chrome.app", displayName: "Chrome")
    let safari = AppRef(path: "/Applications/Safari.app", displayName: "Safari")
    let notes = AppRef(path: "/Applications/Notes.app", displayName: "Notes")
    let windowCounts: [String: Int] = [chrome.path: 3, safari.path: 1, notes.path: 0]

    /// focusedWindowIndex 用来模拟"哪个窗口是当前焦点窗口"；nil 表示读不到。
    func makeSwitcher(focusedWindowIndex: Int? = 0) -> GroupSwitcher {
        GroupSwitcher { app in
            let count = windowCounts[app.path] ?? 0
            return (0..<count).map { index in
                WindowInfo(title: "窗口 \(index + 1)",
                           element: AXUIElementCreateSystemWide(),
                           isMinimized: false,
                           isFocused: focusedWindowIndex == index,
                           frame: NSRect(x: CGFloat(index) * 200, y: 0, width: 200, height: 200),
                           screenIndex: 0,
                           isOnOtherSpace: false, hidden: nil)
            }
        }
    }

    func group(_ apps: [AppRef], shortcut: String = "cmd+4") -> GroupConfig {
        GroupConfig(keyCode: 21, modifiers: [.command], apps: apps)
    }

    print("Chord · 状态机自测")
    print(String(repeating: "─", count: 56))

    // 1. 空组
    check("空组进入返回 nil", makeSwitcher().enter(group: group([])) == nil)

    // 2. 多 app 组：前进 + 回卷
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([chrome, safari]))
        check("进入后落在第 1 个 app", switcher.state?.appIndex == 0)
        switcher.advance()
        check("再按一次前进到第 2 个", switcher.state?.appIndex == 1)
        switcher.advance()
        check("走到末尾回卷到第 1 个", switcher.state?.appIndex == 0)
        check("仍在 app 层", switcher.state?.layer == .apps)
    }

    // 3. 单 app 多窗口：进入时**直接**在窗口层，不用先选一次 app
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([chrome]))
        check("单 app 多窗口：进入时直接在窗口层", switcher.state?.layer == .windows,
              "实际 \(String(describing: switcher.state?.layer))")
        check("直接高亮第 2 个窗口（跳过当前那个）", switcher.state?.windowIndex == 1,
              "实际 \(switcher.state?.windowIndex ?? -1)")
        switcher.advance()
        check("窗口间前进到第 3 个", switcher.state?.windowIndex == 2)
        switcher.advance()
        check("窗口环回卷到第 1 个", switcher.state?.windowIndex == 0)
        switcher.drillUp()
        check("↑ 仍可回到 app 层", switcher.state?.layer == .apps)
        switcher.advance()
        check("从 app 层再按组键又回到窗口层", switcher.state?.layer == .windows)
    }

    // 3b. 下钻起点跟着焦点窗口走（不再假设第 1 个就是当前窗口）
    do {
        let switcher = makeSwitcher(focusedWindowIndex: 1)
        _ = switcher.enter(group: group([chrome]))
        check("焦点在第 2 个 → 高亮从第 3 个开始", switcher.state?.windowIndex == 2,
              "实际 \(switcher.state?.windowIndex ?? -1)")
    }
    do {
        let switcher = makeSwitcher(focusedWindowIndex: 2)
        _ = switcher.enter(group: group([chrome]))
        check("焦点在最后一个 → 环绕到第 1 个", switcher.state?.windowIndex == 0,
              "实际 \(switcher.state?.windowIndex ?? -1)")
    }
    do {
        let switcher = makeSwitcher(focusedWindowIndex: nil)
        _ = switcher.enter(group: group([chrome]))
        check("读不到焦点窗口 → 退回从第 2 个开始", switcher.state?.windowIndex == 1,
              "实际 \(switcher.state?.windowIndex ?? -1)")
    }

    // 4. 单 app 单窗口：没有可选的，停在原地
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([safari]))
        check("单 app 单窗口：进入时留在 app 层", switcher.state?.layer == .apps)
        switcher.advance()
        check("单 app 单窗口时不进窗口层", switcher.state?.layer == .apps)
    }

    // 5. 显式下钻 / 回上层
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([chrome, safari]))
        switcher.drillDown()
        check("↓ 只对多窗口的 app 生效", switcher.state?.layer == .windows)
        switcher.drillUp()
        check("↑ 回到 app 层", switcher.state?.layer == .apps)
        check("回上层后清掉窗口缓存", switcher.state?.windows.isEmpty == true)

        switcher.advance()                      // 高亮 Safari（只有 1 个窗口）
        check("前进到 Safari", switcher.state?.appIndex == 1)
        switcher.drillDown()
        check("单窗口的 app ↓ 无效", switcher.state?.layer == .apps)
    }

    // 6. 没运行的 app 没有窗口可钻
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([notes]))
        switcher.advance()
        check("未运行的 app 不进窗口层", switcher.state?.layer == .apps)
    }

    // 7. 换 app 时窗口缓存作废
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([chrome, safari]))
        switcher.drillDown()
        switcher.drillUp()
        switcher.advance()                      // 换到 Safari
        check("换 app 后窗口缓存清空", switcher.state?.windows.isEmpty == true)
        check("换 app 后窗口下标归零", switcher.state?.windowIndex == 0)
    }

    // 8. 提交内容与终态
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([chrome, safari]))
        let action = switcher.commit()
        if case .activate(let app)? = action {
            check("app 层提交 = 激活该 app", app.displayName == "Chrome")
        } else {
            check("app 层提交 = 激活该 app", false, "拿到 \(String(describing: action))")
        }
        check("提交后状态清空", !switcher.isActive)
    }

    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([chrome]))   // 已在窗口层，高亮第 2 个
        let action = switcher.commit()
        if case .raiseWindow(_, let window)? = action {
            check("窗口层提交 = 提升该窗口", window.title == "窗口 2", "拿到 \(window.title)")
        } else {
            check("窗口层提交 = 提升该窗口", false, "拿到 \(String(describing: action))")
        }
        check("提交后状态清空（窗口层）", !switcher.isActive)
    }

    // 9. 取消
    do {
        let switcher = makeSwitcher()
        _ = switcher.enter(group: group([chrome, safari]))
        switcher.cancel()
        check("取消后状态清空", !switcher.isActive)
        check("取消后提交什么都不做", switcher.commit() == nil)
    }

    print("")
    print(failures == 0 ? "全部通过：\(passed) 项" : "有 \(failures) 项未通过（通过 \(passed) 项）")
    exit(failures == 0 ? 0 : 1)
}
