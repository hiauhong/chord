import ApplicationServices
import Cocoa

/// 一个窗口。窗口层要显示它、要能把它提到前台，所以带上 AX 元素本身。
struct WindowInfo {
    let title: String
    let element: AXUIElement
    let isMinimized: Bool
    /// 当前是否是这个 app 的焦点窗口。
    /// 用它决定下钻时高亮从哪开始——**不再依赖"AX 返回的第 1 个是当前窗口"**，
    /// AX 并不保证顺序（那个假设曾经是本项目唯一没验证的东西）。
    let isFocused: Bool
    /// 窗口在屏幕上的位置（AppKit 坐标，y 向上）。仅用于排序与诊断。
    let frame: NSRect
    /// 所属屏幕在"从左到右"排序后的序号；不在任何屏幕上时为 nil。
    let screenIndex: Int?
    /// 这个窗口**不在任何一块屏的当前桌面**上（它在别的 Space，是缓存里捞回来的）。
    /// HUD 用它换个符号：选它会让那块屏切桌面，这件事该事先看得出。
    let isOnOtherSpace: Bool
    /// 这个窗口在它那块屏的**桌面列表**里排第几（1 起，和 Mission Control 的读法一致）。
    /// 排序要用它：只按位置排的话，"桌面 2" 的窗口位置靠上就会跑到"桌面 1"前头。
    /// nil = 问不出来（拿不到私有接口、或位置对不上），排序时排在该屏最后。
    var desktopIndex: Int?

    /// 非 nil = 这是**占位行**，不是真窗口：它代表"某块屏的某个桌面上还有 N 个窗口"，
    /// 那些窗口 AX 现在看不见（所以没有标题、也没有元素），只能先把那块屏切过去。
    /// 这种情况下 `element` 是 `AXUIElementCreateSystemWide()` 的哨兵值 ——
    /// **任何提窗路径都必须先看这个字段**（`WindowEnumerator.activate` 里处理）。
    let hidden: SpaceBridge.HiddenGroup?

    var isPlaceholder: Bool { hidden != nil }
}

/// 窗口的枚举与提升，全部走 Accessibility。
///
/// 为什么不用 `CGWindowListCopyWindowInfo`：它拿 `kCGWindowName`（标题）需要
/// **屏幕录制权限**，而 AX 的 `kAXTitleAttribute` 只要辅助功能权限就够了——
/// 而那个权限本来就要（CGEventTap 需要）。少要一个权限。
enum WindowEnumerator {

    /// 某个 app 的窗口，**按屏幕的实际左右位置排序**（同屏内再按 x，然后 y）。
    ///
    /// 为什么要排序：AX 返回的顺序是未定义的（实践中多为 z-order），
    /// 那对用户毫无意义——多屏时"第 3 个"到底在哪块屏上要靠猜。
    /// 按屏幕位置排之后，列表顺序和眼睛看到的左右顺序一致。
    static func windows(of app: AppRef) -> [WindowInfo] { windowsIfAvailable(of: app) ?? [] }

    /// 和 `windows(of:)` 同一件事，但**读不到（app 没运行 / 没辅助功能权限）时返回 nil**。
    ///
    /// 区分「读不到」和「读到了、确实是空的」是必要的：窗口全关的 app 属于后者，
    /// 只有后者才该补一发 reopen（见 `activate`）；前者连 app 现在什么状态都不知道，
    /// 乱开窗是越权。
    static func windowsIfAvailable(of app: AppRef) -> [WindowInfo]? {
        guard let bundleID = app.bundleIdentifier,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let fresh = value as? [AXUIElement]
        else { return nil }

        // 把"以前见过、这次不在列表里"的窗口补回来（它们通常在别的桌面，见 seen 的说明）。
        let merged = mergeCache(fresh: fresh,
                                cached: cachedWindows(bundleID: bundleID),
                                same: { CFEqual($0, $1) },
                                alive: { isWindow($0) })
        storeCache(merged.cache, bundleID: bundleID)

        let screens = orderedScreens()
        // 桌面序号：当前桌面上的窗口直接就是"这块屏的第几个桌面"；别的桌面上的（缓存捞回来的）
        // 得按位置去问 CG —— AX 元素换不出 CGWindowID。
        let desktopMap = SpaceBridge.desktopMap(of: running.processIdentifier)

        let infos = merged.shown.compactMap { element -> WindowInfo? in
            // 只要标准窗口。否则助手窗口／浮层（实测飞书有个 WatermarkWidget、
            // 尺寸和屏幕一样大）也会混进切换列表，那些根本不是能"切过去"的东西。
            //
            // role == AXWindow 这一条是必需的额外防线：AX 服务出问题时（实测 macOS 27.2
            // 上出现过，连 System Events 和 Dock 都读不到窗口），`kAXWindows` 会把
            // **app 元素自己**当成窗口返回若干个 —— role 是 AXApplication、subrole 为空、
            // 标题是 app 名、frame 全 0。旧判断放行空 subrole，于是浮层里会出现
            // 三行一模一样的「Chrome」。按 role 卡掉，坏的时候列表为空，而不是一堆假的。
            guard isWindow(element) else { return nil }
            let subrole = string(element, kAXSubroleAttribute)
            if !subrole.isEmpty, subrole != (kAXStandardWindowSubrole as String) { return nil }

            let title = string(element, kAXTitleAttribute)
            let minimized = boolean(element, kAXMinimizedAttribute)
            let focused = boolean(element, kAXFocusedAttribute) || boolean(element, kAXMainAttribute)
            let frame = appKitFrame(of: element)
            let screen = screenIndex(for: frame, in: screens)
            let onOtherSpace = !fresh.contains { CFEqual($0, element) }
            return WindowInfo(title: title.isEmpty ? "（无标题窗口）" : title,
                              element: element,
                              isMinimized: minimized,
                              isFocused: focused,
                              frame: frame,
                              screenIndex: screen,
                              isOnOtherSpace: onOtherSpace,
                              desktopIndex: screen.flatMap { index in
                                  // AX 只给当前桌面的窗口，所以"看得见的"就是当前桌面
                                  onOtherSpace
                                      ? desktopMap.desktopIndex(ofFrame: frame, screenIndex: index)
                                      : desktopMap.currentIndex(screenIndex: index)
                              },
                              hidden: nil)
        }

        // 别的桌面上还有窗口？补占位行（私有接口可用时才补 —— 没有它就没法把窗口变成可选的）。
        // **占位行要一起参与排序**（它只知道自己的桌面序号），所以是"先合再排"，不是排完再追加 ——
        // 追加的话它永远在最底下，桌面的顺序就又乱了（原来就是这么错的）。
        let hidden = placeholders(of: app, pid: running.processIdentifier, known: infos)
        return sorted(infos + hidden)
    }

    /// 「某块屏的第 N 个桌面上还有 M 个窗口」这样的占位行。
    ///
    /// 它们排在真窗口**后面**（`windowsIfAvailable` 是 append），但 HUD 是按屏分列渲染的，
    /// 所以看上去它们是各自那一列的最后一行 ✓。
    private static func placeholders(of app: AppRef, pid: pid_t,
                                     known: [WindowInfo]) -> [WindowInfo] {
        guard SpaceBridge.isAvailable else { return [] }
        let groups = SpaceBridge.hiddenGroups(of: pid, excluding: known.map(\.frame))
        return groups.map(placeholder)
    }

    /// 造一个占位行。诊断命令（`--hidden-windows --switch`）也走这条，
    /// 免得 CLI 和生产各写一份、验的不是同一条路。
    static func placeholder(for group: SpaceBridge.HiddenGroup) -> WindowInfo {
        WindowInfo(title: "第 \(group.spaceIndex) 个桌面 · \(group.windowCount) 个窗口",
                   // 哨兵：占位行没有元素（AX 还没见过那些窗口），见 hidden 的说明
                   element: AXUIElementCreateSystemWide(),
                   isMinimized: false,
                   isFocused: false,
                   frame: .zero,
                   screenIndex: group.screenIndex,
                   isOnOtherSpace: true,
                   desktopIndex: group.spaceIndex,
                   hidden: group)
    }

    // MARK: 见过的窗口（AX 只给当前 Space 的窗口，所以得自己记）

    /// AX 的 `kAXWindowsAttribute` **只返回当前 Space 的窗口**：窗口在别的桌面时，
    /// 它干脆不在返回列表里（社区确认：alt-tab-macos#447；本机实测也如此 ——
    /// CGWindowList 看得见 4 个大窗口，AX 只给 3 个，缺的那个 onscreen=false）。
    /// 症状就是"在桌面 1 开着的窗口，切到桌面 2 按热键就看不见它、也切不过去"。
    ///
    /// 绕法只有一个方向：**趁看得见它的时候把 AX 元素记下来**。AX 没有"按 id 取窗口"
    /// 的接口，没见过的窗口拿不到元素，也就再没有别的办法把它提起来。记下来之后，
    /// 它在别的桌面照样能列出来、能提起来（提起来会让那块屏切回它的桌面，
    /// 和 yabai / Hammerspoon 的 `window:focus()` 是同一条路）。
    ///
    /// 于是有三个记的时机（见 AppDelegate.startWindowWarming）：
    ///   ① 每次查询窗口时顺手记（热键路径本来就要查）；
    ///   ② 空间切换时记两遍（通知到达时旧桌面的窗口可能还在列表里，0.8 秒后新桌面的也在）；
    ///   ③ 每 5 秒巡一遍配置里的 app —— 哪块屏停在某个桌面超过 5 秒，它的窗口就进了缓存。
    ///
    /// **硬限制仍然在**：从没见过的窗口列不出来（窗口开在别的桌面，而那个桌面自从
    /// Chord 启动后没停留过）。AX 不给元素就没法提窗，这条绕不过去，只能说明白。
    private static var seen: [String: [AXUIElement]] = [:]
    private static let seenLock = NSLock()

    private static func cachedWindows(bundleID: String) -> [AXUIElement] {
        seenLock.lock(); defer { seenLock.unlock() }
        return seen[bundleID] ?? []
    }

    private static func storeCache(_ windows: [AXUIElement], bundleID: String) {
        seenLock.lock(); defer { seenLock.unlock() }
        seen[bundleID] = windows
    }

    /// 合并「这次查到的」与「以前见过的」：**纯逻辑**（可脱开 AX 自测）。
    ///
    /// 留下来的缓存项要同时满足：元素还活着（窗口没被关掉）、且这次没查到
    /// （这次查到的用新的那份，缓存里那份就该退休）。
    /// 返回的 `shown` 就是窗口层要显示的列表：查到的在前，别的桌面的接在后面。
    static func mergeCache<T>(fresh: [T], cached: [T],
                              same: (T, T) -> Bool,
                              alive: (T) -> Bool) -> (shown: [T], cache: [T]) {
        let survivors = cached.filter { element in
            alive(element) && !fresh.contains { same($0, element) }
        }
        return (fresh + survivors, fresh + survivors)
    }

    /// 这个元素**真的是一个窗口**吗（role == AXWindow）。
    ///
    /// 缓存和列表都拿它当闸门，两种坏情况一起挡住：
    ///   · 窗口已经被关掉 —— 元素失效，读属性返回 `kAXErrorInvalidUIElement`（实测 -25202）；
    ///   · AX 服务降级 —— `kAXWindows` 返回的是 app 元素自己（role = AXApplication）。
    /// 后者（实测 macOS 27.2 上出现过，连 System Events 和 Dock 都读不到窗口）既不该显示，
    /// **更不该进缓存**：否则服务恢复之后，缓存里那几个假窗口还会混在真窗口里被列出来。
    static func isWindow(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return false }
        return role == kAXWindowRole as String
    }

    /// 把 app 现在的窗口记进缓存。
    ///
    /// **只读窗口列表，不碰 `NSScreen`**，所以可以从后台队列调用（巡检就是这样跑的：
    /// 空间一切换、每 5 秒一次，AX 是跨进程调用，放主线程里跑会耽误热键）。
    static func rememberWindows(of app: AppRef) {
        guard let bundleID = app.bundleIdentifier,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let fresh = value as? [AXUIElement]
        else { return }

        let merged = mergeCache(fresh: fresh,
                                cached: cachedWindows(bundleID: bundleID),
                                same: { CFEqual($0, $1) },
                                alive: { isWindow($0) })
        storeCache(merged.cache, bundleID: bundleID)
    }

    /// 巡检一批 app（空间切换 / 定时器调用）。
    static func refreshSeenWindows(for apps: [AppRef]) {
        for app in apps { rememberWindows(of: app) }
    }

    // MARK: 排序（纯函数，便于用合成窗口测试，不需要 AX 权限）

    /// 窗口落在第几号屏幕（按从左到右的顺序）。
    /// 取**相交面积最大**的那块，所以跨屏的窗口也能有一个确定归属。
    static func screenIndex(for frame: NSRect, in screens: [NSScreen]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let area = intersectionArea(screen.frame, frame)
            guard area > 0 else { continue }
            if best == nil || area > best!.area { best = (index, area) }
        }
        return best?.index
    }

    /// 同一块屏内的排序：先分"行"（上→下），行内再按 x（左→右）。
    ///
    /// 分行用**纵向重叠**判断，而不是固定阈值。原因：窗口布局有两类常见形态，
    /// 固定阈值必然偏向其中一类——
    ///   · 横屏左右并排（普通用法）：两个窗口高低往往差几十到几百 pt，
    ///     固定阈值会把它们误判成两行，顺序变成"高的先"，看着就是乱的；
    ///   · 竖屏上下堆叠（整屏宽的窗口）：完全不重叠，本来就该分两行。
    /// 用"纵向范围是否明显重叠"来分行，两类都对：重叠 → 同一行按左右；
    /// 不重叠 → 上下两行，上面的在前。
    private static func arrangeInRows(_ windows: [WindowInfo]) -> [WindowInfo] {
        // 先按上边缘从上到下排，给分行一个确定的遍历顺序
        let byTop = windows.sorted {
            if $0.frame.maxY != $1.frame.maxY { return $0.frame.maxY > $1.frame.maxY }
            return $0.frame.minX < $1.frame.minX
        }

        var rows: [[WindowInfo]] = []
        var rowTop: CGFloat = 0
        var rowBottom: CGFloat = 0

        for window in byTop {
            let top = window.frame.maxY
            let bottom = window.frame.minY

            if !rows.isEmpty {
                let overlap = min(rowTop, top) - max(rowBottom, bottom)
                let shorter = min(rowTop - rowBottom, top - bottom)
                // 重叠超过较矮那个的 30% 才算同一行。阈值取 0.3 而不是 0.5：
                // 稍微错开一点的并排窗口（很常见）应当算同一行。
                if overlap > 0, shorter > 0, overlap > shorter * 0.3 {
                    rows[rows.count - 1].append(window)
                    rowTop = max(rowTop, top)
                    rowBottom = min(rowBottom, bottom)
                    continue
                }
            }
            rows.append([window])
            rowTop = top
            rowBottom = bottom
        }

        return rows.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// 按 屏幕序号 → **桌面序号** → 行（上→下）→ 行内 x（左→右）排序。
    ///
    /// 桌面这一维是后加的：同一个 app 的窗口可能分布在多个桌面上（别的桌面的那些靠缓存
    /// 或占位行），只按位置排的话，"桌面 2" 的窗口因为位置靠上就跑到"桌面 1"前头去了
    /// —— 用户看到的顺序就是乱的。桌面序号来自 `SpaceBridge`，1 起。
    /// 读不到位置的窗口排在最后，不干扰可用的那些。
    static func sorted(_ windows: [WindowInfo]) -> [WindowInfo] {
        let placed = windows.filter { $0.screenIndex != nil }
        let unplaced = windows.filter { $0.screenIndex == nil }

        var ordered: [WindowInfo] = []
        let byScreen = Dictionary(grouping: placed) { $0.screenIndex! }
        for screen in byScreen.keys.sorted() {
            // 桌面序号未知的（nil）排在该屏最后
            let byDesktop = Dictionary(grouping: byScreen[screen] ?? []) { $0.desktopIndex ?? Int.max }
            for desktop in byDesktop.keys.sorted() {
                ordered += arrangeInRows(byDesktop[desktop] ?? [])
            }
        }
        return ordered + unplaced
    }

    // MARK: 屏幕

    /// 屏幕按**从左到右**排序。
    ///
    /// `NSScreen.screens` 的第 0 个只是"主屏"（有菜单栏那块），其余顺序不保证，
    /// 所以不能直接拿来当左右顺序用。
    static func orderedScreens() -> [NSScreen] {
        NSScreen.screens.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.frame.minY > $1.frame.minY          // 同 x 时上面的优先
        }
    }

    /// AX 给的是 Quartz 全局坐标（原点在**主屏左上角**，y 向下），
    /// 而 `NSScreen.frame` 是 AppKit 坐标（原点在主屏左下角，y 向上）。
    /// 两者只差一次关于主屏高度的翻转。
    static func appKitFrame(of element: AXUIElement) -> NSRect {
        guard let origin = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute)
        else { return .zero }

        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: origin.x,
                      y: primaryHeight - origin.y - size.height,
                      width: size.width,
                      height: size.height)
    }

    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    // MARK: AX 取值

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value as? String) ?? ""
    }

    private static func boolean(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value as? Bool) ?? false
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &result) else { return nil }
        return result
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &result) else { return nil }
        return result
    }

    // MARK: 诊断

    /// 诊断用：打印窗口列表**及其排序依据**。
    ///
    /// 多屏下"顺序对不对"只能对着屏幕看，所以把屏幕序号、x、y、是否焦点都打出来，
    /// 一眼就能核对（见 `Chord --windows`）。
    static func describeOrder(of app: AppRef) -> [String] {
        let windows = windows(of: app)
        guard !windows.isEmpty else {
            return ["（\(app.displayName) 没有可排序的窗口 —— 没在运行，或辅助功能未授权）"]
        }

        var lines = describe(windows)
        let focusedIndex = windows.firstIndex { $0.isFocused }
        lines.append("")
        lines.append("  焦点窗口下标: \(focusedIndex.map(String.init) ?? "无")"
                     + " → 下钻时高亮会从 \((focusedIndex.map { $0 + 1 } ?? 1) % windows.count) 开始")
        return lines
    }

    /// 把一串窗口格式化成可读的行（含排序依据：屏号、x、y）。
    static func describe(_ windows: [WindowInfo]) -> [String] {
        let screens = orderedScreens()
        var lines = ["屏幕（从左到右）: " + screens.enumerated()
            .map { "[\($0.offset)] x=\(Int($0.element.frame.minX)) w=\(Int($0.element.frame.width))" }
            .joined(separator: "  "),
                     "---- 窗口（已按屏幕位置排序）----"]

        for (index, window) in windows.enumerated() {
            let screen = window.screenIndex.map { "屏[\($0)]" } ?? "屏[?]"
            var marks: [String] = []
            if window.isFocused { marks.append("focused") }
            if window.isMinimized { marks.append("minimized") }
            if let desktop = window.desktopIndex { marks.append("桌面\(desktop)") }
            if window.isOnOtherSpace {
                marks.append(window.isPlaceholder ? "其他桌面·选它切过去" : "其他桌面")
            }
            lines.append("[\(index)] \(screen) x=\(Int(window.frame.minX)) y=\(Int(window.frame.minY))"
                         + " w=\(Int(window.frame.width)) h=\(Int(window.frame.height))"
                         + "  \(window.title)"
                         + (marks.isEmpty ? "" : "   ← \(marks.joined(separator: ", "))"))
        }
        return lines
    }

    // MARK: 激活

    /// 一次激活实际走了哪条路。
    ///
    /// 之所以要把它返回出来：**「切过去跟没切一样」是个看不见的症状**，
    /// 日志里能区分「提了窗口 / 只是激活 / 补了一发 reopen / 启动了」，
    /// 排查时就不用猜（`--status` 能看到）。
    enum ActivationOutcome: String {
        case raised      = "激活并把指定窗口提到前台"
        case activated   = "激活（app 有自己的窗口，交给系统选）"
        case reopened    = "激活 + 补一发 reopen（窗口全关，让 app 重新开窗）"
        case launched    = "app 没在运行，启动它"
        case switchedSpace = "把那块屏切到别的桌面（AX 还没记录那里的窗口）"
        case activateFailedSwitch = "退回到只激活（切桌面失败）"
    }

    /// 激活 app，并把某个窗口提到前台。
    ///
    /// 分两步是因为它们管不同的事：`activate` 负责让 app 成为前台 app
    /// （必要时跨 Space / 切出全屏），`kAXRaiseAction` 负责在 app 内部选中具体窗口。
    /// app 不在运行时只启动它——**不会有**指定窗口，因为窗口还不存在。
    ///
    /// `windowQuery` 是注入点（和 `GroupSwitcher` 的 `windowProvider` 同一个理由）：
    /// 默认走 AX；`--reopen-test` 注入一个「返回空列表」的查询，
    /// 好把 reopen 那一半单独拿出来验，不必先去关掉某个 app 的窗口。
    @discardableResult
    static func activate(_ app: AppRef,
                         raising window: WindowInfo? = nil,
                         windowQuery: (AppRef) -> [WindowInfo]? = { windowsIfAvailable(of: $0) }) -> ActivationOutcome {
        let bundleID = app.bundleIdentifier
        let running = bundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }

        if let running {
            if let window {
                // 占位行：那些窗口 AX 现在看不见（在别的桌面），提不了窗 ——
                // 能做的是把那块屏**切过去**，切完 AX 就看得见它们了（下一次列表里就有标题）。
                if let hidden = window.hidden {
                    return switchToHidden(hidden, app: app, running: running)
                }
                running.activate(options: [.activateAllWindows])
                // 刚激活的 app 需要一点点时间才接受 AX 请求
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                }
                return .raised
            }

            // 窗口全关了的 app（进程还活着，比如关掉聊天窗的微信）：
            // 光 `activate` 是**屏幕上什么都不会发生**的——它成为前台 app，
            // 但没有窗口可显示，用户以为"没切过去"。
            // 这时补一发 LaunchServices 的 reopen，等价于在 Dock 上再点一次图标，
            // 由 app 自己决定开哪扇窗（`applicationShouldHandleReopen`）。
            if windowQuery(app)?.isEmpty == true {
                reopen(app, running: running)
                return .reopened
            }

            running.activate(options: [.activateAllWindows])
            return .activated
        }

        if #available(macOS 10.15, *) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: app.bundleURL, configuration: configuration) { _, error in
                if let error { NSLog("Chord: 启动 \(app.displayName) 失败：\(error)") }
            }
        } else {
            NSWorkspace.shared.launchApplication(app.bundleURL.lastPathComponent)
        }
        return .launched
    }

    /// 占位行被选中：把那块屏切到它那个桌面。
    ///
    /// 走 SkyLight 的 `SLSManagedDisplaySetCurrentSpace`（无动画，见 `SpaceBridge`）——
    /// 这是唯一能把"AX 看不见的窗口"变成可选的路径：切过去之后 AX 才给元素和标题。
    /// 顺手把那批窗口记进缓存（`rememberWindows`），于是**切过一次之后就常驻了**，
    /// 下次直接在列表里带标题出现，不用再切。
    private static func switchToHidden(_ group: SpaceBridge.HiddenGroup, app: AppRef,
                                       running: NSRunningApplication) -> ActivationOutcome {
        guard SpaceBridge.setCurrentSpace(display: group.displayIdentifier, space: group.spaceID) else {
            return .activateFailedSwitch
        }
        // 切换本身是同步的，但窗口服务器要几帧才把新桌面的窗口算成"当前"。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            rememberWindows(of: app)
            running.activate(options: [.activateAllWindows])
        }
        return .switchedSpace
    }

    /// 让一个**已经在运行、但一个窗口都没有**的 app 重新开窗。
    ///
    /// 用 `NSWorkspace.openApplication` 而不是自己发 Apple Event
    /// （`kAEReopenApplication`）：发 AE 要「自动化」权限，会弹一个 TCC 授权框，
    /// 而 openApplication 走 LaunchServices，是 Dock 图标点击的同一入口，
    /// **不需要任何新权限**——本项目一直只吃辅助功能这一个权限，不为这件事破例。
    ///
    /// `activates` 同时把 app 提到前台，所以调用方不必再 `activate` 一次。
    ///
    /// **不等回调**：`openApplication` 的 completion 是在主队列上来的，
    /// 而这里正是主线程（事件 tap → 提交切换）——等它必然死锁，
    /// 只能等出半秒白屏。所以结果乐观地当成功，失败那条路在回调里记日志。
    private static func reopen(_ app: AppRef, running: NSRunningApplication) {
        guard #available(macOS 10.15, *) else {
            running.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.bundleURL, configuration: configuration) { _, error in
            guard let error else { return }
            NSLog("Chord: reopen \(app.displayName) 失败：\(error)")
            AppStatus.log("reopen \(app.displayName) 失败（\(error.localizedDescription)），退回只激活")
            running.activate(options: [.activateAllWindows])
        }
    }
}
