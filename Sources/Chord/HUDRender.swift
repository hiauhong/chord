import ApplicationServices
import Cocoa

/// `--render-hud [png]`：把切换浮层渲成图片。
///
/// 为什么需要它：浮层只在按键那一瞬间出现，我没法按、也就看不见它。
/// 窗口行现在按屏幕分列（列 = 一块有窗口的屏幕），布局对不对**只能看**——
/// 所以用合成状态渲出来，自己核对。
func runRenderHUDAndExit() -> Never {
    let arguments = CommandLine.arguments
    let index = arguments.firstIndex(of: "--render-hud")
    let path = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        ?? NSTemporaryDirectory() + "chord-hud.png"

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let screens = WindowEnumerator.orderedScreens()
    print("本机屏幕（从左到右）：")
    for (i, screen) in screens.enumerated() {
        print("  [\(i)] x=\(Int(screen.frame.minX))..\(Int(screen.frame.maxX))")
    }
    print("")

    // 合成状态：3 个窗口，2 个在第 0 块屏、1 个在第 1 块屏 —— 正是用户描述的场景。
    // 第 0 块屏的两个窗口做成一上一下，用来检查"列内上→下"。
    func synthetic(_ title: String, screen: Int, xOffset: CGFloat, yOffset: CGFloat) -> WindowInfo {
        let frame: NSRect
        if screen < screens.count {
            let base = screens[screen].frame
            frame = NSRect(x: base.minX + xOffset, y: base.minY + yOffset, width: 600, height: 400)
        } else {
            frame = NSRect(x: xOffset, y: yOffset, width: 600, height: 400)
        }
        return WindowInfo(title: title,
                          element: AXUIElementCreateSystemWide(),
                          isMinimized: false,
                          isFocused: false,
                          frame: frame,
                          screenIndex: screen < screens.count ? screen : nil,
                          isOnOtherSpace: false,
                          desktopIndex: 1,              // 合成场景都在"第 1 个桌面"上
                          hidden: nil)
    }

    let windows = [
        synthetic("左屏-上", screen: 0, xOffset: 100, yOffset: 900),
        synthetic("左屏-下", screen: 0, xOffset: 100, yOffset: 100),
        synthetic("中屏-唯一", screen: 1, xOffset: 200, yOffset: 400),
    ]

    // 走一遍真实的排序，确保渲染的是生产顺序
    let ordered = WindowEnumerator.sorted(windows)
    let orderedIndex = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.title, $0.offset) })
    print("排序结果（列内顺序应与之一致）：")
    for (i, w) in ordered.enumerated() {
        print("  [\(i)] 屏[\(w.screenIndex.map(String.init) ?? "?")] \(w.title)")
    }
    print("")

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

    let chrome = AppRef(path: "/Applications/Google Chrome.app", displayName: "Google Chrome")

    func state(windows: [WindowInfo], highlight: String) -> GroupSwitcher.State {
        let sorted = WindowEnumerator.sorted(windows)
        let index = sorted.firstIndex { $0.title == highlight } ?? 0
        return GroupSwitcher.State(shortcut: "⌘1", layer: .windows, apps: [chrome],
                                   appIndex: 0, windows: sorted, windowIndex: index)
    }

    // 场景一：用户描述的那个 —— 2 个窗口在左屏、1 个在中间屏
    let hud = SwitcherHUD()
    guard let content = hud.prepareForDiagnostics(state(windows: windows, highlight: "左屏-上")) else {
        print("构建浮层内容失败。")
        exit(1)
    }
    let firstColumns = hud.windowColumnCounts
    check("2 块屏有窗口 → 2 列", firstColumns.count == 2, "实际 \(firstColumns)")
    check("左列 2 个、右列 1 个（列内上→下）", firstColumns == [2, 1], "实际 \(firstColumns)")

    /// app 行整体偏离浮层中线的距离（单 app 组时应该贴在中线上）。
    func appRowOffset(_ content: NSView) -> CGFloat? {
        let tiles = hud.appTileFrames
        guard let first = tiles.first, let last = tiles.last else { return nil }
        return (first.minX + last.maxX) / 2 - content.bounds.midX
    }

    // 单 app 组（⌘1 只有 Chrome）：窗口层里那个格子必须还在中线上。
    // 症状是"按住 ⌘ 按 1，图标从居中变成居左"。
    if let offset = appRowOffset(content) {
        check("窗口层：单 app 的格子居中（偏差 ≤1pt）", abs(offset) <= 1,
              "偏了 \(Int(offset))pt")
    } else {
        check("窗口层：拿得到 app 格子的位置", false)
    }

    guard renderViewToPNG(content, scale: 3, path: path) else {
        print("渲染失败。")
        exit(1)
    }
    print("")
    print("已渲染：\(path)")
    print("  尺寸 \(Int(content.frame.width))x\(Int(content.frame.height))，3 倍输出")

    // app 层也渲一张（-apps 后缀）：窗口层那张只看得到一个 app 格子
    let appCandidates = ["/Applications/Google Chrome.app", "/Applications/Safari.app",
                         "/System/Applications/Notes.app", "/System/Applications/Calculator.app"]
    let groupApps = appCandidates.filter { FileManager.default.fileExists(atPath: $0) }.map {
        AppRef(path: $0, displayName: FileManager.default.displayName(atPath: $0)
                   .replacingOccurrences(of: ".app", with: ""))
    }
    let appsState = GroupSwitcher.State(shortcut: "⌘2", layer: .apps, apps: groupApps,
                                        appIndex: min(1, max(0, groupApps.count - 1)),
                                        windows: [], windowIndex: 0)
    let appsPath = (path as NSString).deletingPathExtension + "-apps.png"
    if let appsContent = hud.prepareForDiagnostics(appsState),
       renderViewToPNG(appsContent, scale: 3, path: appsPath) {
        print("已渲染：\(appsPath)（app 层，\(groupApps.count) 个 app）")
        if let offset = appRowOffset(appsContent) {
            check("app 层：多 app 的格子行居中（偏差 ≤1pt）", abs(offset) <= 1, "偏了 \(Int(offset))pt")
        }
    }

    // 场景四：单 app 组的 **app 层**（⌘1 只有 Chrome 且它只有一个窗口时就是这个样子）。
    // 和上面那张窗口层的图对比，就能看出"进窗口层之后格子跑没跑偏"。
    let singleAppsState = GroupSwitcher.State(shortcut: "⌘1", layer: .apps, apps: [chrome],
                                              appIndex: 0, windows: [], windowIndex: 0)
    let singlePath = (path as NSString).deletingPathExtension + "-single.png"
    if let singleContent = hud.prepareForDiagnostics(singleAppsState),
       renderViewToPNG(singleContent, scale: 3, path: singlePath) {
        print("已渲染：\(singlePath)（app 层，单 app 组）")
        if let offset = appRowOffset(singleContent) {
            let tiles = hud.appTileFrames
            check("app 层：单 app 的格子居中（偏差 ≤1pt）", abs(offset) <= 1,
                  "偏了 \(Int(offset))pt  浮层宽 \(Int(singleContent.bounds.width))  "
                  + "格子 \(tiles.map { "x=\(Int($0.minX))..\(Int($0.maxX))" }.joined(separator: " "))  "
                  + "appRow \(hud.appRowFrame.map { "x=\(Int($0.minX))..\(Int($0.maxX))" } ?? "?")")
        } else {
            check("app 层：拿得到单 app 格子的位置", false)
        }
    }

    // 场景四：占位行（别的桌面上 AX 看不见的窗口）也要能渲出来。
    // 它由私有接口枚举出来、没有元素也没有标题，所以单独用合成数据渲一张核对。
    let placeholder = WindowInfo(title: "第 2 个桌面 · 2 个窗口",
                                 element: AXUIElementCreateSystemWide(),
                                 isMinimized: false, isFocused: false,
                                 frame: .zero, screenIndex: 0, isOnOtherSpace: true,
                                 hidden: SpaceBridge.HiddenGroup(displayIdentifier: "render-test",
                                                                 spaceID: 10, spaceIndex: 2,
                                                                 windowCount: 2, screenIndex: 0))
    // 注意顺序：生产环境里占位行是**接在真窗口后面**的（windowsIfAvailable 是 append），
    // 所以这里也不能再走一遍 sorted()（那会按坐标把它插到中间去）。
    let orderedWindows = WindowEnumerator.sorted(windows)
    let placeholderState = GroupSwitcher.State(shortcut: "⌘1", layer: .windows, apps: [chrome],
                                              appIndex: 0, windows: orderedWindows + [placeholder],
                                              windowIndex: orderedWindows.firstIndex { $0.title == "左屏-上" } ?? 0)
    if let content = hud.prepareForDiagnostics(placeholderState) {
        let placeholderPath = (path as NSString).deletingPathExtension + "-placeholder.png"
        check("占位行落在同一块屏那一列（左列 3 行）", hud.windowColumnCounts == [3, 1],
              "实际 \(hud.windowColumnCounts)")
        if renderViewToPNG(content, scale: 3, path: placeholderPath) {
            print("已渲染：\(placeholderPath)（含一行\"切到另一个桌面\"的占位行）")
        }
    }

    // 场景二：三块屏各一个窗口 → 3 列
    if screens.count >= 3 {
        let three = (0..<3).map { synthetic("屏\($0)", screen: $0, xOffset: 100, yOffset: 300) }
        if let _ = hud.prepareForDiagnostics(state(windows: three, highlight: "屏0")) {
            check("3 块屏各一个窗口 → 3 列", hud.windowColumnCounts == [1, 1, 1],
                  "实际 \(hud.windowColumnCounts)")
        }
    }

    // 场景三：只有一个窗口 / 读不到屏幕位置 → 1 列，不能崩
    let noPosition = [WindowInfo(title: "无位置", element: AXUIElementCreateSystemWide(),
                                 isMinimized: false, isFocused: false,
                                 frame: .zero, screenIndex: nil, isOnOtherSpace: false,
                                 desktopIndex: nil, hidden: nil)]
    if let _ = hud.prepareForDiagnostics(state(windows: noPosition, highlight: "无位置")) {
        check("读不到屏幕位置 → 归到 1 列", hud.windowColumnCounts == [1],
              "实际 \(hud.windowColumnCounts)")
    }

    print("")
    print(failures == 0 ? "全部通过：\(passed) 项" : "有 \(failures) 项未通过（通过 \(passed) 项）")
    exit(failures == 0 ? 0 : 1)
}
