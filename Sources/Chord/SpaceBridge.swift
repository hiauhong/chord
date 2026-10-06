import Cocoa

/// 别的桌面（Space）上的窗口：**AX 看不见它们**。
///
/// AX 的 `kAXWindowsAttribute` 只给"每块屏**当前桌面**"上的窗口（实测：Chrome 有 4 个窗口，
/// AX 只给 2 个，另 2 个 `onscreen=false`）。所以「没去过的桌面上有哪些窗口」这件事，
/// 公开 API 问不出来 —— 只能走 SkyLight 的私有接口。
///
/// 私有接口的边界，写在这里免得日后高估它：
///
/// | 能 | 不能 |
/// |---|---|
/// | 枚举每块屏有哪些桌面（`CGSCopyManagedDisplaySpaces`） | 拿到别的桌面上窗口的**标题** |
/// | 枚举某个桌面里的窗口（`SLSCopyWindowsWithOptionsAndTags`） | |
/// | 窗口属于哪块屏 / 哪个桌面（`SLSCopyManagedDisplayForWindow` / `CGSCopySpacesForWindows`） | |
/// | **无动画**把某块屏切到指定桌面（`SLSManagedDisplaySetCurrentSpace`） | |
///
/// 标题为什么拿不到：AX 只认当前桌面；另一条路 `kCGWindowName` 要**屏幕录制**权限
/// （实测本机 298 个窗口里只有 11 个带名字）。所以别的桌面上的窗口在列表里只能是
/// 「第 N 个桌面 · M 个窗口」这样的占位行，选中它 → 切过去 → 这时 AX 才看得见它们。
///
/// **所有符号都是运行时查找的**：任何一条不在、或调用返回失败，`isAvailable` 就是 false，
/// 上层退回"只列见过的窗口"的老行为。苹果哪天改了语义，最坏情况是退回今天这样，不会崩。
enum SpaceBridge {

    /// 一块屏的桌面情况。
    struct DisplaySpaces {
        /// CGS 的显示器标识（UUID 字符串，形如 `37D8832A-2D66-02CA-B9F7-8F30A301B230`）。
        let identifier: String
        let currentSpace: UInt64
        /// 按 Mission Control 里的顺序（用户说的"桌面 1/2/3"就是这个顺序）。
        let spaces: [UInt64]
    }

    /// 某个 app 在某个桌面上的窗口 —— 这些窗口 AX 现在看不到。
    struct HiddenGroup {
        let displayIdentifier: String
        let spaceID: UInt64
        /// 在这块屏的桌面列表里排第几（1 起，和 Mission Control 的读法一致）。
        let spaceIndex: Int
        let windowCount: Int
        /// 这块屏在"从左到右"里的序号（占位行要落到和真窗口同一列里）。
        let screenIndex: Int
    }

    // MARK: 私有符号（运行时查找）

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindows = @convention(c) (Int32, UInt32, CFArray, UInt32,
                                                    UnsafeMutablePointer<UInt64>?,
                                                    UnsafeMutablePointer<UInt64>?) -> Unmanaged<CFArray>?
    private typealias SpacesForWindows = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplayForWindow = @convention(c) (Int32, UInt32) -> Unmanaged<CFString>?
    private typealias SetCurrentSpace = @convention(c) (Int32, CFString, UInt64) -> Int32

    private struct Symbols {
        let mainConnection: MainConnection
        let displaySpaces: CopyDisplaySpaces
        let windows: CopyWindows
        let spacesForWindows: SpacesForWindows
        let displayForWindow: DisplayForWindow
        let setCurrentSpace: SetCurrentSpace
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                                 RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else {
                AppStatus.log("SpaceBridge: 私有符号 \(name) 不存在 —— 别的桌面的窗口功能关闭")
                return nil
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let main = load("CGSMainConnectionID", MainConnection.self),
              let spaces = load("CGSCopyManagedDisplaySpaces", CopyDisplaySpaces.self),
              let windows = load("SLSCopyWindowsWithOptionsAndTags", CopyWindows.self),
              let forWindows = load("CGSCopySpacesForWindows", SpacesForWindows.self),
              let forWindow = load("SLSCopyManagedDisplayForWindow", DisplayForWindow.self),
              // 切屏是这套东西的**目的**：拿不到它就不能把窗口变成可选的，
              // 占位行也就没有意义 —— 所以缺它就整体关闭。
              let setSpace = load("SLSManagedDisplaySetCurrentSpace", SetCurrentSpace.self)
        else { return nil }

        let probe = Symbols(mainConnection: main, displaySpaces: spaces, windows: windows,
                            spacesForWindows: forWindows, displayForWindow: forWindow,
                            setCurrentSpace: setSpace)
        // 光有符号不够：还得真的能问出东西来（苹果改语义时符号常常还在）。
        guard !displaySpaces(of: probe).isEmpty else {
            AppStatus.log("SpaceBridge: 私有接口在，但问不出桌面列表 —— 功能关闭")
            return nil
        }
        return probe
    }()

    static var isAvailable: Bool { symbols != nil }

    private static var connection: Int32? { symbols.map { $0.mainConnection() } }

    // MARK: 读

    static func displaySpaces() -> [DisplaySpaces] {
        symbols.map { displaySpaces(of: $0) } ?? []
    }

    private static func displaySpaces(of symbols: Symbols) -> [DisplaySpaces] {
        let cid = symbols.mainConnection()
        let raw = symbols.displaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let identifier = entry["Display Identifier"] as? String,
                  let current = (entry["Current Space"] as? [String: Any])?["ManagedSpaceID"]
                    .flatMap(number),
                  let spaceEntries = entry["Spaces"] as? [[String: Any]]
            else { return nil }
            let ids = spaceEntries.compactMap { $0["ManagedSpaceID"].flatMap(number) }
            return DisplaySpaces(identifier: identifier, currentSpace: current, spaces: ids)
        }
    }

    /// `NSNumber` / `Int` / `UInt64` 都可能出现（plist 桥接不保证类型）。
    private static func number(_ value: Any) -> UInt64? {
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return UInt64(value) }
        return nil
    }

    /// 把 NSScreen 映射到 CGS 的显示器标识（两边都要走一遍 UUID）。
    static func displayIdentifier(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// 这个窗口在哪些桌面上（跨桌面时会有多个）。
    static func spaces(ofWindow windowID: UInt32) -> [UInt64] {
        guard let symbols, let cid = connection else { return [] }
        let raw = symbols.spacesForWindows(cid, 0x7, [windowID] as CFArray)?
            .takeRetainedValue() as? [Any] ?? []
        return raw.compactMap(number)
    }

    static func display(ofWindow windowID: UInt32) -> String? {
        guard let symbols, let cid = connection else { return nil }
        return symbols.displayForWindow(cid, windowID)?.takeRetainedValue() as String?
    }

    // MARK: 切屏

    /// 把某块屏**无动画**切到指定桌面。返回是否成功。
    @discardableResult
    static func setCurrentSpace(display identifier: String, space: UInt64) -> Bool {
        guard let symbols, let cid = connection else { return false }
        let error = symbols.setCurrentSpace(cid, identifier as CFString, space)
        if error != 0 { AppStatus.log("SpaceBridge: 切桌面失败 error=\(error)") }
        return error == 0
    }

    // MARK: 桌面序号（排序用）

    /// 一次枚举里要用的桌面信息。**合成一份**是为了不用每个窗口都去问一遍 CGS。
    ///
    /// 窗口怎么对应到"第几个桌面"：AX 元素拿不到 CGWindowID（那要另一个私有接口
    /// `_AXUIElementGetWindow`），所以按**位置**匹配 —— 两边都从窗口服务器取，
    /// 差不到 1pt，够用。匹配不上的给 nil（排序时排在该屏最后）。
    struct DesktopMap {
        /// 屏序号 → 当前桌面序号（1 起）
        var currentIndexByScreen: [Int: Int] = [:]
        /// 窗口（按位置）→ 它那块屏、那个桌面
        var windows: [(frame: NSRect, screenIndex: Int, desktopIndex: Int)] = []

        func currentIndex(screenIndex: Int) -> Int? { currentIndexByScreen[screenIndex] }

        func desktopIndex(ofFrame frame: NSRect, screenIndex: Int) -> Int? {
            windows.first { abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2
                          && abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2
                          && $0.screenIndex == screenIndex }?.desktopIndex
        }
    }

    static func desktopMap(of pid: pid_t) -> DesktopMap {
        var map = DesktopMap()
        guard symbols != nil else { return map }
        let displays = displaySpaces()
        guard !displays.isEmpty else { return map }

        let screens = WindowEnumerator.orderedScreens()
        var identifierByScreen: [Int: String] = [:]
        for (index, screen) in screens.enumerated() {
            if let identifier = displayIdentifier(of: screen) { identifierByScreen[index] = identifier }
        }
        for (screenIndex, identifier) in identifierByScreen {
            guard let display = displays.first(where: { $0.identifier == identifier }),
                  let index = display.spaces.firstIndex(of: display.currentSpace) else { continue }
            map.currentIndexByScreen[screenIndex] = index + 1
        }

        for window in candidateWindows(of: pid) {
            guard let screenIndex = WindowEnumerator.screenIndex(for: window.frame, in: screens),
                  let identifier = identifierByScreen[screenIndex],
                  let display = displays.first(where: { $0.identifier == identifier })
            else { continue }
            let windowSpaces = spaces(ofWindow: window.id)
            guard let target = display.spaces.first(where: { windowSpaces.contains($0) }),
                  let index = display.spaces.firstIndex(of: target) else { continue }
            map.windows.append((window.frame, screenIndex, index + 1))
        }
        return map
    }

    // MARK: 别的桌面上、AX 看不见的窗口

    /// 找出「这个 app 在这块屏的**别的桌面**上还有几个窗口」。
    ///
    /// 判据很直接：窗口所在的桌面集合里**没有**这块屏的当前桌面 → AX 看不见它。
    /// （跨桌面的窗口会在多个桌面上，只要有一个是当前桌面就算看得见。）
    ///
    /// `knownFrames` 是已经列出来的窗口（AX 看得见的 + 缓存里见过的）——按位置排掉它们，
    /// 否则"去过一次的桌面"会被重复统计一遍（那些窗口我们已经有标题了）。
    ///
    /// 只统计"像个正经窗口"的：CG 层 0、alpha 不为 0、尺寸够大。CGWindowList 会把
    /// 一堆 1×1 的辅助窗口也算进来（实测 Chrome 有 33 个层 0 窗口，其中正经窗口只有 4 个）。
    static func hiddenGroups(of pid: pid_t, excluding knownFrames: [NSRect] = []) -> [HiddenGroup] {
        guard symbols != nil else { return [] }
        let displays = displaySpaces()
        guard !displays.isEmpty else { return [] }

        // 每块屏的屏幕序号 → 显示器标识（占位行要落到和真窗口同一列里）
        var identifierByScreen: [Int: String] = [:]
        let screens = WindowEnumerator.orderedScreens()
        for (index, screen) in screens.enumerated() {
            if let identifier = displayIdentifier(of: screen) { identifierByScreen[index] = identifier }
        }

        var counts: [String: [UInt64: Int]] = [:]      // 显示器标识 → 桌面 → 窗口数
        var screenOf: [String: Int] = [:]
        for window in candidateWindows(of: pid) {
            // 已经列出来的窗口跳过（差几点的容差：两边各自从窗口服务器取，可能有亚像素差）
            if knownFrames.contains(where: { abs($0.minX - window.frame.minX) < 2
                                          && abs($0.minY - window.frame.minY) < 2
                                          && abs($0.width - window.frame.width) < 2
                                          && abs($0.height - window.frame.height) < 2 }) { continue }
            let windowSpaces = spaces(ofWindow: window.id)
            guard !windowSpaces.isEmpty else { continue }
            // 落在哪块屏：用窗口位置判（和真窗口分列用的是同一套）
            guard let screenIndex = WindowEnumerator.screenIndex(for: window.frame, in: screens),
                  let identifier = identifierByScreen[screenIndex],
                  let display = displays.first(where: { $0.identifier == identifier })
            else { continue }
            // 有一个桌面是当前桌面 → AX 看得见，不是"别的桌面"
            guard !windowSpaces.contains(display.currentSpace) else { continue }
            // 目标桌面取"这块屏的桌面列表里"最靠前的那个（跨屏窗口的其它桌面不算）
            let target = display.spaces.first { windowSpaces.contains($0) } ?? windowSpaces[0]
            counts[identifier, default: [:]][target, default: 0] += 1
            screenOf[identifier] = screenIndex
        }

        return counts.flatMap { identifier, bySpace -> [HiddenGroup] in
            let display = displays.first { $0.identifier == identifier }
            return bySpace.map { space, count in
                HiddenGroup(displayIdentifier: identifier,
                            spaceID: space,
                            spaceIndex: (display?.spaces.firstIndex(of: space) ?? 0) + 1,
                            windowCount: count,
                            screenIndex: screenOf[identifier] ?? 0)
            }
        }
        .sorted { ($0.screenIndex, $0.spaceIndex) < ($1.screenIndex, $1.spaceIndex) }
    }

    private struct CandidateWindow {
        let id: UInt32
        let frame: NSRect
    }

    private static func candidateWindows(of pid: pid_t) -> [CandidateWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  ((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 240, height >= 160
            else { return nil }
            // Quartz 坐标（左上原点）→ AppKit 坐标（左下原点）
            let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
                ?? NSScreen.screens.first?.frame.height ?? 0
            let frame = NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            return CandidateWindow(id: id, frame: frame)
        }
    }
}
