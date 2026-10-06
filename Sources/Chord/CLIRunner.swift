import Carbon.HIToolbox
import Cocoa

// MARK: - 配置的机械验证

/// `--normalize-config`：读进来再写回去，相当于配置的 gofmt。
///
/// 用途有两个：一是把旧格式（keyCode + modifiers 数字）迁移成可手写的 `shortcut` 字符串；
/// 二是验证写回是否**规范化**——例如手写的 `"shift+cmd+4"` 应被写成 `"cmd+shift+4"`。
func runNormalizeConfigAndExit() -> Never {
    let store = ConfigStore()
    let before = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
    guard store.save() else {
        print("写回失败，见系统日志。")
        exit(1)
    }
    let after = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
    print("已规范化：\(store.fileURL.path)")
    print(before == after ? "内容无变化（本来就是规范形式）" : "内容已改写")
    exit(0)
}

/// `--ui-metrics`：把配置窗实例化但不显示，量出布局实际要求的尺寸。
///
/// 存在的理由：界面"太宽"这类问题没法靠读代码判断——可能是默认值给大了，
/// 也可能是某条约束（比如那行很长的配置文件路径）把宽度撑住了，
/// 那种情况下改默认值根本没用。量一下就知道是哪种。
func runUIMetricsAndExit() -> Never {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    // 先清掉**本进程域里**可能留下的陈旧窗口尺寸：裸二进制的 UserDefaults 落在 `Chord` 域
    // （和 .app 的 com.hiauhong.chord 不是一个），上一次量尺寸/渲染写进去的值会让窗口
    // 一创建就套上那个尺寸 —— 量到的就不是默认几何了（这个坑咬过两次）。
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(SettingsWindowController.frameAutosaveName)")

    let controller = SettingsWindowController()
    guard let window = controller.window, let content = window.contentView else {
        print("无法创建配置窗。")
        exit(1)
    }
    // **第一件事就是摘掉 autosave**：窗口在 init 里已经把上次存的尺寸套上了，
    // 而量尺寸会摆弄窗口、退出时 AppKit 又会把它写回去 —— 于是"量一次"就把用户的
    // 窗口宽度改掉了（实测踩过两次：一次存成 350，一次存成 433）。
    // 摘掉之后，量到的是**默认**几何（这才是要核对的东西），也不会写回任何东西。
    let savedFrameNote = UserDefaults.standard.string(
        forKey: "NSWindow Frame \(window.frameAutosaveName)")
    window.setFrameAutosaveName("")

    // `--authorized`：按"已授权"的样子量（提示条不显示）。CLI 进程自己没权限，
    // 不显式声明量到的就是带提示条的版本 —— 而那个版本会宽 70 多 pt。
    if CommandLine.arguments.contains("--authorized") {
        controller.isHotkeyTapAvailable = { true }
        controller.reload()
        print("（按已授权状态量：提示条不显示）")
    }
    content.layoutSubtreeIfNeeded()

    let contentSize = content.frame.size
    let fitting = content.fittingSize
    let autosaveKey = "NSWindow Frame \(window.frameAutosaveName)"
    let saved = savedFrameNote

    print("配置窗：")
    print("  约束要求尺寸 : \(Int(fitting.width)) x \(Int(fitting.height))   ← 布局真正需要的，改窄要动的是这个")
    print("  当前内容尺寸 : \(Int(contentSize.width)) x \(Int(contentSize.height))")
    print("  允许的最小尺寸: \(Int(window.minSize.width)) x \(Int(window.minSize.height))")
    if let saved {
        print("  autosave     : \(autosaveKey) = \(saved)")
        print("                 （当前尺寸来自这里，用户拖过的尺寸会盖过代码里的默认值）")
    } else {
        print("  autosave     : 无记录，当前用的是代码里的默认尺寸")
    }

    // 列名是界面的一部分，但它同时也是可以机械核对的东西。
    func firstTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTable(subview) { return found }
        }
        return nil
    }
    if let table = firstTable(content) {
        let columns = table.tableColumns
            .map { "\($0.title)(\(Int($0.width)))" }
            .joined(separator: " | ")
        print("  表头         : \(table.headerView == nil ? "无" : "有")")
        print("  列           : \(columns)")
        print("  行高         : \(Int(table.rowHeight))")
    } else {
        print("  表头         : 找不到 NSTableView")
    }

    print("  控件 frame   :")
    for line in controller.layoutReport() { print(line) }

    print("  最长一行     : \(controller.widestRowTrailingGap())")
    print("  宽度 → 右端空隙：")
    // 第一个就是**当前生效的默认宽度**（它按列宽和最长的一行 app 数算出来），
    // 后面几个是余量测试：窗口再窄下去图标条会被压缩。
    let operativeWidth = SettingsWindowController.defaultWidth(
        apps: ConfigStore.shared.groups, columnWidth: controller.shortcutColumnWidth)
    for width in [Int(operativeWidth), 440, 420, 400, 390, 380, 370, 360, 350] {
        window.setContentSize(NSSize(width: CGFloat(width), height: content.bounds.height))
        content.layoutSubtreeIfNeeded()
        print("    \(width)pt → \(controller.widestRowTrailingGap())")
    }

    // 快捷键的显示字形要逐个验覆盖：系统 UI 字体不含全部符号，
    // 缺了会渲染成方框（实测缺 ⇥ ↩ ⇞ ⇟）。
    let missing = ShortcutCodec.missingDisplayGlyphs()
    print("  字形覆盖     : \(missing.isEmpty ? "全部有字形 ✅" : "缺 " + missing.joined(separator: "、"))")
    exit(0)
}

/// `--windows [app 路径或 bundle id]`：按 AX 返回顺序打印窗口列表。
///
/// 不传参数就用当前前台 app。用途是验证一个假设：
/// `drillDown` 认为"第 1 个窗口就是当前窗口"，所以下钻时从第 2 个开始高亮。
/// AX 不保证顺序，这里把 focused / main 标记一并打出，对一眼就知道站不站得住。
func runWindowDumpAndExit() -> Never {
    let app = resolveAppArgument(after: "--windows")

    print("app      : \(app.displayName)  [\(app.bundleIdentifier ?? "?")]")
    print("窗口顺序（AX 返回的原始顺序）：")
    for line in WindowEnumerator.describeOrder(of: app) { print(line) }
    print("")
    print("顺序规则：屏幕从左到右 → 桌面（第 1 个桌面在前）→ 同屏同桌面内按行（上→下）→ 行内按 x。")
    print("把上面每一行的 屏[n] / x 对着实际屏幕核对即可；focused 那个是下钻的起点参照。")
    exit(0)
}

/// `--windows` / `--reopen-test` 共用：取命令行里紧跟在 `flag` 后的那个参数，
/// 按「路径或 bundle id 包含」在配置里找 app；不传则用当前前台 app。
func resolveAppArgument(after flag: String) -> AppRef {
    let arguments = CommandLine.arguments
    let filter = arguments.firstIndex(of: flag).flatMap {
        arguments.indices.contains($0 + 1) && !arguments[$0 + 1].hasPrefix("--") ? arguments[$0 + 1] : nil
    }

    if let filter {
        let matches = ConfigStore.shared.groups
            .flatMap(\.apps)
            .filter { $0.path.contains(filter) || ($0.bundleIdentifier ?? "").contains(filter) }
        if let first = matches.first { return first }

        // 配置里没有的也认：直接给 .app 路径，或给 bundle id 让 LaunchServices 找。
        // 诊断不该先要求"它恰好在配置里"——排查的对象往往正是一个配置外的 app。
        if let url = appURL(matching: filter) {
            return AppRef(path: url.path,
                          displayName: FileManager.default.displayName(atPath: url.path)
                            .replacingOccurrences(of: ".app", with: ""))
        }

        print("配置里找不到匹配「\(filter)」的 app，磁盘与 LaunchServices 里也没有。")
        exit(1)
    }

    guard let front = NSWorkspace.shared.frontmostApplication, let url = front.bundleURL else {
        print("拿不到前台 app；请显式传 app 路径或 bundle id。")
        exit(1)
    }
    return AppRef(path: url.path, displayName: front.localizedName ?? url.lastPathComponent)
}

/// 把 `--windows` / `--reopen-test` 的参数当路径或 bundle id 解析成 .app。
func appURL(matching filter: String) -> URL? {
    if filter.contains("/") {
        let url = URL(fileURLWithPath: (filter as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) { return url.standardizedFileURL }
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: filter)
}

/// `--hidden-windows [app] [--switch 屏序号:桌序号]`：别的桌面上那些 **AX 看不见的窗口**。
///
/// 这套东西全靠 SkyLight 的私有接口（见 `SpaceBridge`），所以先把它单独做成一条命令：
/// 能不能枚举、算得对不对、切屏能不能成，都在这里对着一块屏看一眼就知道。
///
/// 不带参数：只列「这个 app 在哪块屏的第几个桌面上还有几个窗口」。
/// `--switch 0:2`：把那块屏切到第 2 个桌面（**会真的切过去**，屏幕会变），
/// 然后复查 AX 能不能看见那些窗口了 —— 这正是占位行被选中时要做的事。
func runHiddenWindowsAndExit() -> Never {
    let arguments = CommandLine.arguments
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }

    guard SpaceBridge.isAvailable else {
        print("私有接口不可用 → 只能列出「见过的窗口」（当前行为）")
        exit(1)
    }

    print("显示器与桌面（来自 SkyLight 私有接口）：")
    let displays = SpaceBridge.displaySpaces()
    let screens = WindowEnumerator.orderedScreens()
    for (index, screen) in screens.enumerated() {
        let identifier = SpaceBridge.displayIdentifier(of: screen)
        let match = displays.first { $0.identifier == identifier }
        print("  屏[\(index)] \(Int(screen.frame.width))x\(Int(screen.frame.height))  "
              + "标识=\(identifier ?? "?")  "
              + "当前桌面=\(match.map { String($0.currentSpace) } ?? "?")  "
              + "共 \(match?.spaces.count ?? 0) 个桌面：\(match?.spaces.map(String.init).joined(separator: ",") ?? "-")")
    }
    print("")

    let app = resolveAppArgument(after: "--hidden-windows")
    guard let bundleID = app.bundleIdentifier,
          let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    else {
        print("\(app.displayName) 没在运行。")
        exit(1)
    }

    print("\(app.displayName) 的窗口：")
    print("  AX 看得见 \(WindowEnumerator.windows(of: app).count) 个：")
    for line in WindowEnumerator.describe(WindowEnumerator.windows(of: app)).dropFirst(2) {
        print("    \(line)")
    }
    let groups = SpaceBridge.hiddenGroups(of: running.processIdentifier)
    print("  别的桌面上还有 \(groups.reduce(0) { $0 + $1.windowCount }) 个（AX 看不见）：")
    if groups.isEmpty {
        print("    （没有 —— 要么都在当前桌面，要么这个 app 就没有别的窗口）")
    }
    for group in groups {
        print("    屏[?] 标识=\(group.displayIdentifier) → 第 \(group.spaceIndex) 个桌面"
              + "（Space \(group.spaceID)）：\(group.windowCount) 个窗口")
    }

    guard let switchTarget = value(after: "--switch") else {
        print("")
        print("加 --switch 屏序号:桌序号 可以真的切过去看一眼（例如 --switch 0:2）。")
        exit(0)
    }

    let parts = switchTarget.split(separator: ":")
    guard parts.count == 2, let screenIndex = Int(parts[0]), let spaceIndex = Int(parts[1]),
          screens.indices.contains(screenIndex),
          let identifier = SpaceBridge.displayIdentifier(of: screens[screenIndex]),
          let display = displays.first(where: { $0.identifier == identifier }),
          display.spaces.indices.contains(spaceIndex - 1)
    else {
        print("--switch 参数看不懂：给「屏序号:桌序号」，例如 0:2")
        exit(1)
    }

    let target = display.spaces[spaceIndex - 1]
    print("")
    print("把屏[\(screenIndex)] 切到第 \(spaceIndex) 个桌面（Space \(target)）——走**生产路径**…")
    // 走 WindowEnumerator.activate 而不是直接调 SpaceBridge：验的必须是热键提交时那条路。
    let group = SpaceBridge.HiddenGroup(displayIdentifier: identifier, spaceID: target,
                                        spaceIndex: spaceIndex, windowCount: 0,
                                        screenIndex: screenIndex)
    let outcome = WindowEnumerator.activate(app, raising: WindowEnumerator.placeholder(for: group))
    print("activate 的结论：\(outcome.rawValue)")
    // 切屏本身同步，但"新桌面的窗口算成当前"要几帧；生产路径里还有 0.35 秒的延迟记账。
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))

    let now = SpaceBridge.displaySpaces().first { $0.identifier == identifier }?.currentSpace
    let visible = WindowEnumerator.windows(of: app)
    print("复查：当前桌面=\(now.map(String.init) ?? "?")（期望 \(target)）")
    print("      AX 现在看得见 \(visible.count) 个窗口")
    for line in WindowEnumerator.describe(visible).dropFirst(2) { print("        \(line)") }
    print("")
    print("切回去了吗：跑 `--hidden-windows \(app.displayName) --switch \(screenIndex):1` 之类切回原桌面。")
    exit(0)
}

///
/// `--watch-windows [app] [--seconds N] [--raise N]`：持续观察窗口列表。
///
/// 每秒看一次这个 app 的窗口（**含别的桌面上见过的**），有变化就打印。
/// 它验的是那条 AX 的硬限制带来的行为：
///   · 把某块屏切到另一个桌面 → 那个窗口本来会从列表里消失，现在应该还在，
///     只是标着「其他桌面」（靠缓存捞回来的）；
///   · `--raise N` 在观察结束时把第 N 个窗口提起来，再复查它是否回到当前桌面 ——
///     这一条验的是缓存**有没有用**：跨桌面提窗到底会不会让那块屏切回它的桌面。
///
/// 缓存按进程存活，所以"先看见、后切走"必须在同一次运行里发生 —— 这也正是
/// 它只能做成一个持续观察的命令、而不是两个单次命令的原因。
func runWatchWindowsAndExit() -> Never {
    let arguments = CommandLine.arguments
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }

    let app = resolveAppArgument(after: "--watch-windows")
    let seconds = value(after: "--seconds").flatMap(Double.init) ?? 45
    let raiseIndex = value(after: "--raise").flatMap(Int.init)

    let stamp = { () -> String in
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    print("观察 \(app.displayName) 第 \(Int(seconds)) 秒：每秒查一次，只在窗口集合变化时打印。")
    print("（本进程辅助功能=\(Accessibility.isTrusted ? "已授权" : "未授权，查不到窗口")）")
    print("")

    var lastSignature: String?
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let windows = WindowEnumerator.windows(of: app)
        let signature = windows.map { "\($0.title)|\($0.isOnOtherSpace)|\($0.isMinimized)" }
            .joined(separator: " // ")
        if signature != lastSignature {
            lastSignature = signature
            let otherSpace = windows.filter(\.isOnOtherSpace).count
            print("[\(stamp())] \(windows.count) 个窗口"
                  + "（当前桌面 \(windows.count - otherSpace) + 其他桌面 \(otherSpace)）")
            for line in WindowEnumerator.describe(windows).dropFirst(2) { print("    " + line) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }

    guard let raiseIndex else {
        print("")
        print("（加 --raise N 可以让第 N 个窗口试一次：它若在别的桌面，看那块屏会不会切过去。）")
        exit(0)
    }

    let windows = WindowEnumerator.windows(of: app)
    guard windows.indices.contains(raiseIndex - 1) else {
        print("没有第 \(raiseIndex) 个窗口（当前 \(windows.count) 个）。")
        exit(1)
    }

    let target = windows[raiseIndex - 1]
    print("")
    print("提起第 \(raiseIndex) 个「\(target.title)」（其他桌面=\(target.isOnOtherSpace)）…")
    WindowEnumerator.activate(app, raising: target)
    // activate 里的提窗是延后 0.05 秒做的，桌面切换动画再占一会儿。
    RunLoop.main.run(until: Date().addingTimeInterval(2))

    let after = WindowEnumerator.windows(of: app).first { $0.title == target.title }
    switch after {
    case .none:
        print("复查：找不到这个窗口了 ❌")
        exit(1)
    case .some(let window) where window.isOnOtherSpace:
        print("复查：它仍在别的桌面 —— 提窗没有把桌面切过去 ❌（缓存列出来了也切不过去）")
        exit(1)
    case .some:
        print("复查：它已经回到当前桌面 ✅（跨桌面提窗会让那块屏切回它的桌面）")
        exit(0)
    }
}

/// `--reopen-test [app] [--force-reopen]`：把**提交切换里那发 reopen** 单独跑一遍。
///
/// 为什么要单独一个入口：症状是「窗口关掉的 app，切过去跟没切一样」，
/// 修法是补一发 LaunchServices reopen（Dock 图标点击的同一入口）。
/// 但这半边默认验不了：本命令从 shell 跑时**没有辅助功能权限**，
/// 读不出窗口列表，真实路径根本不会走到 reopen（app 本身通过 `open` 启动，是有权限的）。
/// 所以 `--force-reopen` 注入一个「窗口查询返回空」的桩，直接验 reopen 能不能开窗。
func runReopenTestAndExit() -> Never {
    let app = resolveAppArgument(after: "--reopen-test")
    let force = CommandLine.arguments.contains("--force-reopen")

    print("app      : \(app.displayName)  [\(app.bundleIdentifier ?? "?")]")
    print("运行中   : \(app.isRunning ? "是" : "否（reopen 会变成启动）")")
    print("辅助功能 : \(Accessibility.isTrusted ? "已授权" : "未授权（本进程读不到窗口）")")
    print("查询窗口 : \(describeWindows(WindowEnumerator.windowsIfAvailable(of: app)))")
    print("模式     : " + (force
        ? "强制（注入空窗口列表，不依赖辅助功能权限）"
        : "真实（用 AX 查到的窗口数 —— 和热键提交完全同一条路）"))
    print("")

    // 真实模式下 windowQuery 就是生产用的那一个；force 下换成「读到 0 个」的桩。
    let outcome = force
        ? WindowEnumerator.activate(app, windowQuery: { _ in [] })
        : WindowEnumerator.activate(app)
    // `openApplication` 是异步的，completion 在主队列上来。这里是 CLI，不能立刻 exit：
    // 请求还没送到 LaunchServices 就被收尸了（踩过：日志里一个 REOPEN 都没有）。
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))

    print("结果     : \(outcome.rawValue)")
    if let after = WindowEnumerator.windowsIfAvailable(of: app) {
        print("复查窗口 : \(after.count) 个")
    } else {
        print("复查窗口 : 读不到（本进程没有辅助功能权限）——请对着屏幕看窗口有没有回来")
    }
    if let failure = AppStatus.recent(5).last(where: { $0.contains("reopen") }) {
        print("日志     : \(failure)")
    }
    print("")
    print("对照方法：先关掉该 app 的窗口（进程别退），跑这条命令，看窗口是否回来。")
    print("本进程没权限时加 --force-reopen，验证的是「reopen 能不能开窗」这半边。")
    print("同样的动作在热键路径上会自动发生，落到 \(AppStatus.fileURL.lastPathComponent) 的「结果=」里。")
    exit(0)
}

/// 给「查询窗口」那一行用：区分读不到和读到 0 个。
private func describeWindows(_ windows: [WindowInfo]?) -> String {
    guard let windows else { return "读不到（app 没在运行，或没有辅助功能权限）" }
    return "\(windows.count) 个"
}

/// `--status`：打印 app 自己写下的运行状态。
///
/// 它回答的是 CLI 答不了的问题：**通过 `open` 启动的 .app 眼中**权限是什么状态。
/// 直接跑二进制的 TCC 身份是父进程，结论会误导（踩过）。
func runStatusAndExit() -> Never {
    let lines = AppStatus.recent(30)
    print("状态文件 : \(AppStatus.fileURL.path)")
    print("当前进程 : \(AppStatus.environmentSummary())")
    print("")
    if lines.isEmpty {
        print("（还没有记录。先 open build/Chord.app 启动一次 app。）")
    } else {
        print("app 写下的最近 \(lines.count) 条：")
        for line in lines { print("  " + line) }
    }
    exit(0)
}

/// `--window-order`：打印 app 上次写下的窗口顺序诊断。
///
/// 窗口顺序只能由有辅助功能权限的进程去读，也就是**通过 open 启动的 app**。
/// 所以先在菜单栏点「诊断：把窗口顺序写入文件」，再用这个命令看结果。
func runWindowOrderAndExit() -> Never {
    print("诊断文件 : \(AppStatus.windowOrderURL.path)")
    print("")
    guard let text = try? String(contentsOf: AppStatus.windowOrderURL, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        print("（还没有内容。先在菜单栏点「诊断：把窗口顺序写入文件」。）")
        exit(1)
    }
    print(text)
    exit(0)
}

/// `--login-item`：查看/切换登录项（开机自启）。
///
/// 注意和权限那件事同源：**从 shell 直接跑这个二进制时，它没有正经的 bundle 身份**，
/// `SMAppService.mainApp` 可能报 notFound —— 那是这个进程的问题，不是 app 的。
/// 要看 app 的真实状态，用 `--status` 读它启动时写下的那行。
func runLoginItemAndExit() -> Never {
    let arguments = CommandLine.arguments
    if arguments.contains("--enable") || arguments.contains("--disable") {
        let enable = arguments.contains("--enable")
        switch LaunchAtLogin.setEnabled(enable) {
        case .success(let description):
            print("已请求\(enable ? "开启" : "关闭")：\(description)")
        case .failure(let error):
            print("操作失败：\(error.localizedDescription)")
        }
    }

    print("本进程看到的登录项状态：\(LaunchAtLogin.description)")
    print("（从 shell 直接跑二进制时这个结论可能不准，原因同上）")
    print("")
    let lines = AppStatus.recent(60).filter { $0.contains("开机自启") }
    if lines.isEmpty {
        print("app 还没记录过登录项状态。启动一次 app 后可用 --status 查看。")
    } else {
        print("app 记录过的登录项相关日志：")
        for line in lines { print("  " + line) }
    }
    exit(0)
}

/// `--dump-config`：把磁盘上的配置原样打印出来。
///
/// 存在的理由：配置窗的**视觉**我没法自动验证，但**数据**可以。
/// 有了它，模型改动就有确定的回归信号：seed → 断言 → dump。
func runDumpConfigAndExit() -> Never {
    let store = ConfigStore()
    print("配置文件 : \(store.fileURL.path)")

    guard !store.groups.isEmpty else {
        print("组数     : 0（空配置）")
        exit(0)
    }

    print("组数     : \(store.groups.count)")
    for (index, group) in store.groups.enumerated() {
        let shortcut = group.hasRequiredModifier ? group.shortcutLabel : "(未绑定)"
        print("[\(index + 1)] \(shortcut)   app=\(group.apps.count)   由拖动决定的顺序 ↓")
        for (appIndex, app) in group.apps.enumerated() {
            let running = app.isRunning ? "运行中" : "未运行"
            print("      \(appIndex). \(app.displayName)  [\(running)]  \(app.bundleIdentifier ?? "?")")
        }
    }
    exit(0)
}

/// `--seed-config`：写一份演示配置，供配置窗/状态机开发时用。幂等，已有配置就不动。
///
/// 故意不覆盖已有配置：这是个开发辅助，不该有毁掉真实配置的能力。
func runSeedConfigAndExit() -> Never {
    let store = ConfigStore()
    guard store.groups.isEmpty else {
        print("已有 \(store.groups.count) 组配置，跳过 seed（不覆盖）。")
        exit(0)
    }

    // 按本机实际存在的 app 选，挑不到就少几个，不编造路径。
    let firstGroupCandidates = [
        "/Applications/Google Chrome.app",
        "/Applications/Safari.app",
        "/Applications/Notes.app",
    ]
    let secondGroupCandidates = [
        "/Applications/Warp.app",
        "/Applications/Utilities/Terminal.app",
        "/System/Applications/Utilities/Terminal.app",
    ]

    func existingApps(_ paths: [String]) -> [AppRef] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }.map { path in
            let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            return AppRef(path: path, displayName: name)
        }
    }

    store.addGroup(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command])
    for app in existingApps(firstGroupCandidates) { store.appendApp(app, groupAt: 0) }

    store.addGroup(keyCode: UInt16(kVK_ANSI_5), modifiers: [.command])
    for app in existingApps(secondGroupCandidates) { store.appendApp(app, groupAt: 1) }

    print("已写入演示配置：\(store.fileURL.path)")
    print("  第 1 组 ⌘4 → \(store.groups[0].apps.count) 个 app")
    print("  第 2 组 ⌘5 → \(store.groups.count > 1 ? store.groups[1].apps.count : 0) 个 app")
    exit(0)
}

// MARK: - 环境自检

/// 命令行自检模式。退出码：
///   0 = 全部通过
///   1 = 有检查项未通过
///   2 = 辅助功能未授权，无法自检
///
/// 给脚本用：`Chord --self-test`
func runSelfTestInTerminal() -> Never {
    print("Chord · 命令行自检")
    print(String(repeating: "─", count: 56))
    print("可执行文件 : \(Bundle.main.bundlePath)")
    print("bundle id  : \(Bundle.main.bundleIdentifier ?? "（无 bundle —— 裸二进制，TCC 授权会很不稳定）")")
    print("辅助功能   : \(Accessibility.isTrusted ? "已授权 ✅" : "未授权 ❌")")
    print("")

    guard Accessibility.isTrusted else {
        print("无法自检：能吞键的 defaultTap 在未授权时创建失败（listenOnly 能创建但收不到事件）。")
        print("")
        print("授权路径：系统设置 → 隐私与安全性 → 辅助功能")
        print("  · 若列表里找不到本 app，把 .app 拖进去")
        print("  · 若改过二进制或签名，需要先删掉再重新添加")
        exit(2)
    }

    // 必须用局部常量持住 tester：run() 里的定时器只弱引用它，
    // 写成 SelfTest().run { … } 会让实例立刻释放，自检永远不结束。
    let tester = SelfTest()
    tester.run { checks in
        var allPassed = true
        for check in checks {
            if !check.passed { allPassed = false }
            print("\(check.passed ? "✅" : "❌") \(check.name)")
            print("     \(check.detail)")
        }
        print("")
        print(allPassed ? "结论：全部通过。" : "结论：有项目未通过。")
        exit(allPassed ? 0 : 1)
    }

    CFRunLoopRun()
    fatalError("run loop 意外退出")
}
