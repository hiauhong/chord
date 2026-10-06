import ApplicationServices
import Cocoa

/// CGEventTap 的封装。
///
/// 一个 tap 同时拿到 keyDown / keyUp / flagsChanged —— 组热键需要的三样东西
/// （前进用的按键、松手提交用的修饰键状态、吞键能力）都在这一个入口里，
/// 不需要再拼 Carbon 热键 + 全局 flagsChanged 监听那一套。
///
/// 两个必须处理的坑：
///   1. 回调超时（默认 0.25s）或用户输入打断会让系统**禁用** tap，
///      必须在回调里立刻重新启用，否则表现为"热键时灵时不灵"。
///   2. 回调运行在事件流上，绝不能做重活（窗口枚举、AX 查询、渲染），
///      否则会把自己拖到上面那个超时里。重活一律异步搬到主线程。
final class HotkeyTap {

    struct KeyEvent {
        let type: CGEventType
        let keycode: Int64
        let flags: CGEventFlags
        let isRepeat: Bool

        /// 同一批修饰键的 AppKit 表示。
        /// 两者的标准修饰位布局一致（`maskCommand` == `.command` == 1<<20），
        /// 所以这里只换类型、不做换算，方便上层直接用 NSEvent.ModifierFlags 的 API。
        var nsFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)) }
    }

    enum Level {
        /// 会话级。默认选择。
        case session
        /// HID 级，更靠前，能在别的启动器之前拿到按键；权限要求更高。
        case hid
    }

    enum Placement {
        /// 插在事件流前面，可吞键。
        case head
        /// 追加在末尾，只能旁观（配合 listenOnly 做验证用）。
        case tail
    }

    /// 返回 true 表示吞掉这个事件，前台 app 收不到。
    var onEvent: ((KeyEvent) -> Bool)?
    /// tap 被系统禁用并重新启用后回调，用于诊断。
    var onReenabled: ((String) -> Void)?

    private let level: Level
    private let placement: Placement
    private let listenOnly: Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 自我保持：C 回调通过 userInfo 持有的是**不保留**指针，
    /// 所以 tap 启用期间必须自己保自己。否则 HotkeyTap 一旦先于 tap 释放，
    /// 下一次回调就会在已释放内存上做 swift_retain —— 实测崩过
    /// （EXC_BAD_ACCESS，栈是 swift_retain → HotkeyTap.handle）。
    private var selfRetain: HotkeyTap?

    /// 收到的事件总数，便于判断 tap 是否真的在工作。
    private(set) var receivedCount = 0

    init(level: Level = .session, placement: Placement = .head, listenOnly: Bool = false) {
        self.level = level
        self.placement = placement
        self.listenOnly = listenOnly
    }

    /// 我们关心的事件类型。
    static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// 创建并启用 tap。返回 false 通常意味着辅助功能未授权。
    @discardableResult
    func start() -> Bool {
        stop()

        guard let created = CGEvent.tapCreate(
            tap: level == .session ? .cgSessionEventTap : .cghidEventTap,
            place: placement == .head ? .headInsertEventTap : .tailAppendEventTap,
            options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<HotkeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        tap = created
        selfRetain = self
        let createdSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = createdSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), createdSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil

        // 放开自我保持时**延后一拍**：可能已经有一次回调被派发出去了，
        // 它还需要这点时间跑完。回调都跑在主 run loop 上，所以下一轮
        // main 队列执行时它们必然已经结束。
        if let held = selfRetain {
            DispatchQueue.main.async { _ = held }
            selfRetain = nil
        }
    }

    deinit {
        // 有 selfRetain 之后这里不该发生：tap 非 nil 就意味着 selfRetain 非 nil，
        // 对象不可能正在释放。留着当不变量检查。
        if tap != nil {
            NSLog("Chord: HotkeyTap 在 tap 仍启用时被释放 —— 这会导致回调访问已释放内存")
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统禁用 → 立刻重新启用。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onReenabled?(type == .tapDisabledByTimeout ? "回调超时" : "用户输入打断")
            return Unmanaged.passUnretained(event)
        }

        receivedCount += 1

        let keyEvent = KeyEvent(
            type: type,
            keycode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )

        if onEvent?(keyEvent) == true { return nil }
        return Unmanaged.passUnretained(event)
    }
}
