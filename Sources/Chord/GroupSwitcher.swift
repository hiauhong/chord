import Cocoa

/// 组切换的状态机。
///
/// 刻意不碰 UI、不碰事件流：它只接受「前进 / 下钻 / 回上层 / 提交 / 取消」几个动词。
/// 因此可以脱开辅助功能权限单测（见 `Chord --state-test`），HUD 只是它状态的一个观察者。
///
/// 不变量（整个交互只有这几条，没有特例）：
///   - 进入组时高亮落在用户排的第 1 位，此时**不提交**。
///   - 重复按组键 = **在当前层前进**；当前层没有「下一个」时**自动下钻一层**。
///     这条让单 app 组不需要任何特例：第二下自然落到窗口层。
///   - 走到末尾**回卷**。
///   - 提交时机由事件层决定（和弦被打破），本类只负责给出「提交什么」。
final class GroupSwitcher {

    enum Layer {
        case apps
        case windows
    }

    struct State {
        var shortcut: String
        var layer: Layer
        var apps: [AppRef]
        var appIndex: Int
        var windows: [WindowInfo]
        var windowIndex: Int

        var highlightedApp: AppRef? {
            apps.indices.contains(appIndex) ? apps[appIndex] : nil
        }

        var highlightedWindow: WindowInfo? {
            windows.indices.contains(windowIndex) ? windows[windowIndex] : nil
        }

        /// 当前层有多少项——HUD 用它显示 `2/5` 之类的进度。
        var layerCount: Int { layer == .apps ? apps.count : windows.count }
        var layerIndex: Int { layer == .apps ? appIndex : windowIndex }
    }

    /// 提交时要执行的动作。
    enum Action {
        /// 只激活 app，用哪个窗口交给系统（它会给最近使用的那个）。
        case activate(AppRef)
        /// 激活 app 并把指定窗口提到前台。
        case raiseWindow(AppRef, WindowInfo)
    }

    private(set) var state: State?

    var isActive: Bool { state != nil }

    /// 窗口枚举注入进来，便于测试；生产环境用 AX。
    /// 每次进入某个 app 时**只查一次并缓存**——AX 是跨进程 IPC，
    /// 放进按键循环里会卡。
    private let windowProvider: (AppRef) -> [WindowInfo]

    init(windowProvider: @escaping (AppRef) -> [WindowInfo] = WindowEnumerator.windows(of:)) {
        self.windowProvider = windowProvider
    }

    // MARK: 进入与退出

    @discardableResult
    func enter(group: GroupConfig) -> State? {
        guard !group.apps.isEmpty else { return nil }   // 空组无处可去
        state = State(shortcut: group.shortcutLabel,
                      layer: .apps,
                      apps: group.apps,
                      appIndex: 0,
                      windows: [],
                      windowIndex: 0)

        // 组里只有一个 app 时，"选 app"这一步没有可选的——显示它只是多一次按键。
        // 直接进窗口层；它只有 ≤1 个窗口时 drillDown 自己会什么都不做。
        if group.apps.count == 1 { drillDown() }

        return state
    }

    func cancel() { state = nil }

    // MARK: 前进

    /// 重复按组键。
    @discardableResult
    func advance() -> State? {
        guard var current = state else { return nil }

        switch current.layer {
        case .apps:
            if current.apps.count > 1 {
                current.appIndex = (current.appIndex + 1) % current.apps.count
                current.windows = []            // 换了 app，缓存的窗口作废
                current.windowIndex = 0
                state = current
            } else {
                // 层里只有它自己 —— 没有「下一个」，于是下钻。
                return drillDown()
            }
        case .windows:
            if current.windows.count > 1 {
                current.windowIndex = (current.windowIndex + 1) % current.windows.count
                state = current
            }
            // 0/1 个窗口时无处可去，停在原地
        }
        return state
    }

    /// 显式下钻（HUD 里按 ↓）。
    ///
    /// 初始高亮落在**第 2 个**窗口而不是第 1 个：第 1 个正是"不按下钻、直接松手"
    /// 会得到的那个，跳过它才有意义，这也正是 Cmd+` 的语义。
    @discardableResult
    func drillDown() -> State? {
        guard var current = state, current.layer == .apps,
              let app = current.highlightedApp else { return state }

        let windows = windowProvider(app)
        guard windows.count > 1 else { return state }   // 0 个（没运行）或 1 个都没得选

        current.windows = windows
        // 起点落在**焦点窗口的下一个**（按列表顺序环绕）。
        // 焦点那个正是"不按下钻、直接松手"会得到的，跳过它才有意义；
        // 而列表现在按屏幕位置排序，所以"下一个"就是它右边那一个。
        //
        // 这里刻意不再假设"第 1 个就是当前窗口"——AX 不保证返回顺序，
        // 那是本项目唯一一个曾经靠推测的假设，现在改成显式找焦点窗口。
        let focusedIndex = windows.firstIndex { $0.isFocused } ?? 0
        current.windowIndex = (focusedIndex + 1) % windows.count
        current.layer = .windows
        state = current
        return state
    }

    /// 回到 app 层（HUD 里按 ↑）。
    @discardableResult
    func drillUp() -> State? {
        guard var current = state, current.layer == .windows else { return state }
        current.layer = .apps
        current.windows = []
        current.windowIndex = 0
        state = current
        return state
    }

    // MARK: 提交

    /// 提交当前高亮。**调用后状态清空**——提交是终态，不会留下一个半开的环。
    func commit() -> Action? {
        guard let current = state, let app = current.highlightedApp else {
            state = nil
            return nil
        }
        defer { state = nil }

        if current.layer == .windows, let window = current.highlightedWindow {
            return .raiseWindow(app, window)
        }
        return .activate(app)
    }
}
