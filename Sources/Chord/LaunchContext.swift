import Cocoa

/// 这次启动是**谁拉起来的**。
///
/// 需求：开机自启那一次**不弹配置窗** —— 登录时自己冒一个窗口出来是打扰；
/// 而手动 `open`/双击 Chord 是"我要配置"的明确信号，该照常弹。
///
/// 两条判据，按可靠性排序：
///
/// **① open-application 事件里的 `keyAELaunchedAsLogInItem`（`lgit`）标记（权威）。**
/// LaunchServices 每次"打开"这个 app —— 双击、`open`、登录项拉起 —— 都会派发
/// `kAEOpenApplication`；登录项那一次带 `lgit` 参数。这是 Apple 给的正路
/// （[Launch Apple Event Constants]），Mozilla 在 `SMAppService` 时代也是这么判的。
/// 由 `AppDelegate` 的事件处理器写进来。实测两个要点：
/// 该事件在 `applicationDidFinishLaunching` **之前**就派发完了（所以那时已经读得到），
/// 而 `NSAppleEventManager.currentAppleEvent` 在 `applicationDidFinishLaunching` 里是
/// **nil** —— 想直接读当前事件是读不到的，必须自己装处理器。
///
/// **② 时序兜底。** 留这一手是因为 ① 只能证明"是登录项拉的"，证不了反面 ——
/// 登录项那次要是**没带** `lgit`（历史版本的系统、或哪天行为变了），光看事件就会误判成手动。
/// 所以再看一眼进程是不是在开机后极短时间内起来的：`CLOCK_UPTIME_RAW` 是**含睡眠**的开机时长
/// （`systemUptime` 和 `kern.boottime` 在睡眠场景下对不上，别拿它们配对），
/// 于是 `boot 墙钟 = now − uptime`，再和 LaunchServices 给的 `launchDate` 相减。
/// 两侧同一套墙钟，中途校时也是同向偏移、差值不变。
///
/// （实测：事件本身几乎总是有 —— 连直接 exec bundle 里的裸二进制、完全不经过
/// LaunchServices，AppKit 自己也会派发一个 `kAEOpenApplication`（`lgit` 缺失），
/// 所以别指望靠"没收到事件"来判断是不是开发模式。）
///
/// 两条信号之间是 **OR**：谁说"这是登录项拉的"就按静默走。理由是代价不对称 ——
/// 误判成登录项只是"这一次双击没弹窗"（再双击一次即可：那时 app 已在跑，
/// 走 `applicationShouldHandleReopen` 照样弹）；误判成手动则是每次开机都被打扰。
enum LaunchContext {

    /// 开机后多久以内起来的算"登录项拉的"（**只用于兜底**）。
    ///
    /// 90 秒的依据（本机实测）：开机 08:25:52 → Stats 08:26:49、Raycast 08:26:50、
    /// TextSync 08:26:50，Chord 自己 +59 秒；也就是说登录项都在开机后一分钟内起来。
    /// 别放太宽：万一权威信号失效，放太宽会把"登录后手动打开"也误吞
    /// （历史上看到过登录慢到开机后 3 分钟的机器，那种情况指望 ① 那条信号兜住）。
    private static let loginWindow: TimeInterval = 90

    /// 这个环境变量 / 命令行开关可以覆盖判定，只为**验证**用：
    /// 登录项那一次没法在开发会话里复现，靠它把两条分支都走一遍。
    ///   `CHORD_LAUNCH=login`、或 `--login-launch` → 强制按「登录项拉起」走；
    ///   `CHORD_LAUNCH=manual`、或 `--manual-launch` → 强制按手动走。
    private static let overrideKey = "CHORD_LAUNCH"
    private static let forceLoginLaunchFlag = "--login-launch"
    private static let forceManualLaunchFlag = "--manual-launch"

    enum Origin: String {
        case loginItem
        case manual
        /// 判不了（`launchDate` 拿不到，例如直接跑 bundle 内的二进制做开发）。
        /// 按手动处理——宁可多弹一次窗，也不要让"配置…"变得打不开。
        case unknown
    }

    // MARK: ① open-application 事件

    /// 事件里读到的来源。`nil` = 这次压根没收到那个事件。
    private(set) static var appleEventOrigin: Origin?

    /// 由 `AppDelegate` 的 `kAEOpenApplication` 处理器调用（在 `applicationDidFinishLaunching` 之前）。
    static func noteOpenApplication(launchedAsLoginItem: Bool) {
        appleEventOrigin = launchedAsLoginItem ? .loginItem : .manual
    }

    // MARK: 判定

    /// 这一次启动的来源。每次现算：事件可能比第一次读它的时候更早/更晚落定。
    static var origin: Origin {
        if let forced = forcedOrigin { return forced }
        // ① 权威信号：事件说了算
        if appleEventOrigin == .loginItem { return .loginItem }
        // ② 兜底：没事件、或事件说不是，但进程就是在开机后几十秒内起来的
        let timed = timingOrigin
        if timed == .loginItem { return .loginItem }
        return appleEventOrigin ?? timed
    }

    static var launchedByLoginItem: Bool { origin == .loginItem }

    private static var forcedOrigin: Origin? {
        if let forced = ProcessInfo.processInfo.environment[overrideKey] {
            return forced == "loginItem" || forced == "login" ? .loginItem : .manual
        }
        if CommandLine.arguments.contains(forceLoginLaunchFlag) { return .loginItem }
        if CommandLine.arguments.contains(forceManualLaunchFlag) { return .manual }
        return nil
    }

    /// 实测的开机后启动秒数（拿不到 launchDate 时为 nil）。
    private static var secondsSinceBoot: TimeInterval? {
        guard let launchDate = NSRunningApplication.current.launchDate else { return nil }
        return launchDate.timeIntervalSince1970 - bootWallClock
    }

    private static var timingOrigin: Origin {
        guard let elapsed = secondsSinceBoot else { return .unknown }
        return elapsed <= loginWindow ? .loginItem : .manual
    }

    /// 开机的墙钟时刻 = 现在 − 含睡眠的开机时长。
    private static var bootWallClock: TimeInterval {
        var uptime = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &uptime)
        return Date().timeIntervalSince1970
            - (Double(uptime.tv_sec) + Double(uptime.tv_nsec) / 1_000_000_000)
    }

    /// 写给日志/`--status` 看的一行判据，出问题时能直接对着数字复盘：
    /// 两条信号**各自**说了什么都要露出来 —— 这样下一次真开机就能看出 ① 到底灵不灵，
    /// 不用猜。
    static var description: String {
        let event: String
        switch appleEventOrigin {
        case .loginItem: event = "open 事件带 lgit"
        case .manual:    event = "open 事件没带 lgit"
        case .unknown:   event = "open 事件来源未知"
        case nil:        event = "没收到 open 事件"
        }
        let timing = secondsSinceBoot.map {
            String(format: "开机后 %.1f 秒启动，时序阈值 %.0f 秒", $0, loginWindow)
        } ?? "拿不到 launchDate"
        return "\(origin.rawValue)（\(event)｜\(timing)）"
    }
}
