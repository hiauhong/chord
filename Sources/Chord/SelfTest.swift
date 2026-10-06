import ApplicationServices
import Cocoa

/// 环境自检：用一对 tap（head 吞键 + tail 旁观）配合合成事件，
/// 验证组热键所依赖的每一条假设。
///
/// 为什么需要**两个** tap：吞键是"事件没有到达下游"这种否定性事实，
/// 光看自己的回调无法证明。必须在 head 吞掉之后确认 tail 也没看到，
/// 才算真的吞掉了；同时用另一个**不被吞**的组合做对照，
/// 排除"tail 本来就什么都收不到"这种假阳性。
///
/// 为什么需要合成事件：我没有权限替你按键盘，而合成事件同样流经 session tap，
/// 所以这一整套可以在你授权后自动跑完，不需要你手动按任何键。
final class SelfTest {

    struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// 被吞掉的测试键：K
    private let swallowKeycode: Int64 = 40
    /// 对照组（不被吞）：J
    private let controlKeycode: Int64 = 38
    private let commandKeycode: CGKeyCode = 55
    private let combo: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    private var head: HotkeyTap?
    private var tail: HotkeyTap?

    private var headCreated = false
    private var tailCreated = false
    private var headSawTargetDown = false
    private var headSawTargetUp = false
    private var headSawFlagsChanged = false
    private var headSawRepeat = false
    private var headSwallowed = 0
    private var tailSawControl = false
    private var tailSawTarget = false
    private var reenabled: [String] = []

    /// 等 tap 在 run loop 上真正生效，再注入事件。
    private let startDelay: TimeInterval = 0.4
    /// 给事件流留出穿行时间，然后判定。
    private let settleDelay: TimeInterval = 1.4

    func run(completion: @escaping ([Check]) -> Void) {
        head = HotkeyTap(level: .session, placement: .head, listenOnly: false)
        tail = HotkeyTap(level: .session, placement: .tail, listenOnly: true)

        head?.onReenabled = { [weak self] reason in self?.reenabled.append(reason) }

        head?.onEvent = { [weak self] event in
            guard let self else { return false }
            let isTarget = event.keycode == self.swallowKeycode && self.hasCombo(event.flags)

            if isTarget, event.type == .keyDown {
                self.headSawTargetDown = true
                if event.isRepeat { self.headSawRepeat = true }
            }
            if isTarget, event.type == .keyUp { self.headSawTargetUp = true }
            if event.type == .flagsChanged, event.flags.contains(.maskCommand) {
                self.headSawFlagsChanged = true
            }

            if isTarget { self.headSwallowed += 1 }
            return isTarget   // 只吞目标组合
        }

        tail?.onEvent = { [weak self] event in
            guard let self else { return false }
            guard event.type == .keyDown || event.type == .keyUp else { return false }
            if event.keycode == self.controlKeycode { self.tailSawControl = true }
            if event.keycode == self.swallowKeycode { self.tailSawTarget = true }
            return false
        }

        headCreated = head?.start() ?? false
        tailCreated = tail?.start() ?? false

        RunLoop.main.add(Timer(timeInterval: startDelay, repeats: false) { [weak self] _ in
            self?.injectSyntheticEvents()
        }, forMode: .common)

        RunLoop.main.add(Timer(timeInterval: settleDelay, repeats: false) { [weak self] _ in
            self?.finish(completion: completion)
        }, forMode: .common)
    }

    private func hasCombo(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskAlternate) && flags.contains(.maskControl)
    }

    /// 注入一串固定事件。注入点在 hidEventTap，因此会真正流经 session tap。
    private func injectSyntheticEvents() {
        let source = CGEventSource(stateID: .hidSystemState)

        func postFlags(_ flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: commandKeycode, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }

        func postKey(_ keycode: Int64, down: Bool, repeatFlag: Bool = false) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keycode), keyDown: down)
            event?.flags = combo
            if repeatFlag { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event?.post(tap: .cghidEventTap)
        }

        postFlags([.maskCommand])                                  // 修饰键可达性
        postKey(controlKeycode, down: true)                        // 对照：应当穿过 head 到达 tail
        postKey(controlKeycode, down: false)
        usleep(60_000)
        postKey(swallowKeycode, down: true, repeatFlag: true)      // 目标：应当被 head 吞掉
        usleep(60_000)
        postKey(swallowKeycode, down: false)
        postFlags([])
    }

    private func finish(completion: @escaping ([Check]) -> Void) {
        head?.stop()
        tail?.stop()

        var checks: [Check] = []

        checks.append(Check(
            name: "head tap 创建（可吞键）",
            passed: headCreated,
            detail: headCreated ? "session / headInsert / defaultTap" : "创建失败 —— 辅助功能未授权"
        ))

        checks.append(Check(
            name: "tail tap 创建（只旁观）",
            passed: tailCreated,
            detail: tailCreated ? "session / tailAppend / listenOnly" : "创建失败"
        ))

        let keysReached = headSawTargetDown && headSawTargetUp
        checks.append(Check(
            name: "keyDown / keyUp 可达",
            passed: keysReached,
            detail: "down=\(headSawTargetDown) up=\(headSawTargetUp)"
        ))

        checks.append(Check(
            name: "flagsChanged 可达（松手提交靠它）",
            passed: headSawFlagsChanged,
            detail: headSawFlagsChanged ? "读到 ⌘ 按下" : "没收到修饰键事件"
        ))

        // 吞键生效 = 对照组到达 tail，而目标组合没有。
        let swallowWorks = tailSawControl && !tailSawTarget
        checks.append(Check(
            name: "吞键生效（起点）",
            passed: swallowWorks,
            detail: "对照组合到达 tail=\(tailSawControl)，目标组合到达 tail=\(tailSawTarget)，head 吞掉 \(headSwallowed) 次"
        ))

        checks.append(Check(
            name: "autorepeat 标志可读",
            passed: headSawRepeat,
            detail: headSawRepeat
                ? "读到 isRepeat=true"
                : "未读到 —— 若其余项通过，多半是合成事件被系统规范化，需用真按键复核"
        ))

        if !reenabled.isEmpty {
            checks.append(Check(
                name: "tap 被禁用后自动重新启用",
                passed: true,
                detail: "发生过 \(reenabled.count) 次：\(reenabled.joined(separator: "、"))"
            ))
        }

        completion(checks)
    }
}
