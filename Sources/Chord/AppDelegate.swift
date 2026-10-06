import Cocoa

/// 应用装配：菜单栏、全 app 唯一的 CGEventTap、窗口管理、事件路由。
///
/// 事件路由是全项目最需要小心的地方，因为它同时承担三件事：
/// 录制、组切换、放行。任何一条判错的后果都是"前台 app 收不到按键"
/// 或"热键时灵时不灵"。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    /// 菜单里的「开机自启」，用来反映/切换状态（勾选态跟系统实际状态走）。
    private var launchAtLoginItem: NSMenuItem?
    private var settings: SettingsWindowController?
    /// 未授权期间每秒回查一次；授权一到就启动 tap、收起提示条。
    private var permissionPoll: Timer?
    /// 系统授权弹窗每个进程只会出现一次，之后「去授权」改为直接打开设置面板。
    private var didRequestPrompt = false

    /// 全 app 唯一的 CGEventTap：录制与组切换共用它，
    /// 因此「能录进去的组合」和「能触发的组合」语义天然一致。
    private var tap: HotkeyTap?

    // 切换
    private let switcher = GroupSwitcher()
    private let hud = SwitcherHUD()
    /// 这一轮切换所属的修饰键，用于判断"和弦是否被打破"。
    private var activeModifiers: NSEvent.ModifierFlags = []
    /// 这一轮的组键 keyCode（循环键就是它自己）。
    private var activeKeyCode: UInt16 = 0
    /// 浮层的延迟显示：快速点一下（按一次就松手）不该让浮层闪一下。
    private var hudShowTimer: Timer?
    /// 窗口缓存巡检（见 startWindowWarming）。
    private var windowWarmTimer: Timer?
    private var spaceObserver: NSObjectProtocol?

    // MARK: 生命周期

    /// 装 `kAEOpenApplication` 的处理器。
    ///
    /// 用户每次"打开"这个 app（Finder 双击、`open`、登录项拉起）都会派发这个事件，
    /// 登录项那一次带着 `keyAELaunchedAsLogInItem`。这是判定"这次是不是开机自启"的
    /// **权威信号**，比按开机时长猜可靠得多（见 `LaunchContext`）。
    ///
    /// 必须在 `applicationWillFinishLaunching` 里装：实测该事件在
    /// `applicationDidFinishLaunching` **之前**就派发完了，装晚了就永远收不到
    /// （而 `NSAppleEventManager.currentAppleEvent` 在 didFinishLaunching 里是 nil）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenApplication(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication))
    }

    @objc private func handleOpenApplication(_ event: NSAppleEventDescriptor,
                                            reply: NSAppleEventDescriptor) {
        let launchedAsLoginItem = event
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?
            .booleanValue ?? false
        LaunchContext.noteOpenApplication(launchedAsLoginItem: launchedAsLoginItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStatus.log(AppStatus.environmentSummary())
        buildMenuBar()
        startHotkeyTap()
        refreshMenuBar()
        startWindowWarming()

        // 别人又启动了一次（双击、脚本、两份拷贝…）：把配置窗弹出来当作回应 ——
        // 菜单栏 app 没有 Dock 图标，不给点反馈的话看着就像"启动失败了"。
        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showSettingsNotification, object: nil, queue: .main) { [weak self] _ in
            AppStatus.log("有第二个实例被启动 → 把配置窗弹出来")
            self?.showSettings()
        }

        // 启动后自动写一次窗口顺序诊断：让"多屏排序对不对"不依赖人工点菜单。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.writeWindowOrderDump()
        }

        // 权限提示就在配置窗顶部，不再单独弹自检窗。
        // 只有**开机自启那一次**不弹窗：登录时自己冒一个窗口出来是打扰。
        // 手动 open / 双击照旧弹窗——那是"我要配置"的明确信号；
        // 别的实例启动时发来的通知也照旧弹（见上面的 observer）。
        //
        // 判据在 `applicationWillFinishLaunching` 装的那个 open-application 事件处理器里
        // 已经落定（登录项拉起时事件带 lgit 标记），时序只是兜底 —— 见 `LaunchContext`。
        //
        // 注意这里**不按授权状态分流**（曾经写成"未授权才安静"，是错的）：
        // 权限是持久的，白天授权过、晚上开机自启那次照样会弹。登录那次一律安静。
        // 代价是少了状态反馈，所以菜单栏图标兼当状态灯（见 refreshMenuBar），
        // 缺权限时它就是那个 `⚠️`。
        if LaunchContext.launchedByLoginItem {
            AppStatus.log("开机自启启动 → 不弹配置窗，只留菜单栏图标"
                          + "（辅助功能=\(tap != nil ? "已授权" : "未授权，图标带 ⚠️")）")
        } else {
            showSettings()
        }
        watchForPermissionIfNeeded()
    }

    // MARK: 窗口缓存巡检

    /// 让"别的桌面上的窗口"也能被列出来。
    ///
    /// AX 的 `kAXWindowsAttribute` **只返回当前 Space 的窗口**，所以窗口一旦切到别的桌面，
    /// 就再也查不到它了 —— 症状是"在桌面 1 开着的窗口，切到桌面 2 按热键看不见、也切不过去"。
    /// 唯一的绕法是趁看得见它的时候把 AX 元素记下来（详见 `WindowEnumerator.seen`）。
    ///
    /// 两个时机：
    ///   ① 空间切换 —— 通知到达时旧桌面的窗口可能还在 AX 列表里，立刻记一遍；
    ///      0.8 秒后再记一遍，那时新桌面的窗口才在列表里。两遍合起来两头都收进缓存。
    ///   ② 每 5 秒巡一遍配置里的 app —— 谁在某个桌面停留超过 5 秒，窗口就进了缓存。
    ///      （只在空间切换时记是不够的：用户可能一直待在某个桌面，从没触发过切换。）
    ///
    /// 巡检走后台队列：AX 是跨进程调用，卡住的 app 会拖住调用方，而主线程上跑着热键 tap。
    private func startWindowWarming() {
        // ConfigStore 在主线程读，读到的快照再交给后台。
        let configuredApps: () -> [AppRef] = { ConfigStore.shared.groups.flatMap(\.apps) }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                let now = configuredApps()
                DispatchQueue.global(qos: .utility).async {
                    WindowEnumerator.refreshSeenWindows(for: now)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let later = configuredApps()
                    DispatchQueue.global(qos: .utility).async {
                        WindowEnumerator.refreshSeenWindows(for: later)
                    }
                }
            }

        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            let snapshot = configuredApps()
            DispatchQueue.global(qos: .utility).async {
                WindowEnumerator.refreshSeenWindows(for: snapshot)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowWarmTimer = timer

        // 启动时先记一遍，别等第一个 5 秒。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let first = configuredApps()
            DispatchQueue.global(qos: .utility).async {
                WindowEnumerator.refreshSeenWindows(for: first)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 用户"重新打开"了这个 app（Finder 里双击、Dock 里点图标）。
    ///
    /// 这一步不是可选的：开机自启那一次不弹窗，于是"已经有一份在跑"成了常态。
    /// 此时 `open` 不会起第二个进程（LaunchServices 直接复用），
    /// 单实例那条分布式通知也就**轮不到触发**——不接这个回调的话，
    /// 双击 Chord 会像什么都没发生。配置窗是全 app 唯一的入口，所以这里就是把它弹出来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppStatus.log("用户重新打开了 app（可见窗口=\(hasVisibleWindows)）→ 弹配置窗")
        showSettings()
        return true
    }

    // MARK: 菜单栏

    /// 菜单栏图标的字号与基线微调。系统默认走菜单栏字体（约 13pt），夹在一排 18~20pt 的
    /// 第三方图标里偏小；但直接放大又会**偏高**，因为状态栏按钮是**按基线**摆字的：
    /// 实测字号变大时墨迹底边纹丝不动、只往上长（13pt 时 ⌘ 的中心在正中上方 0.5pt，
    /// 18pt 时已经偏上 2.25pt），所以放大多少就得往下压回多少。
    ///
    /// 16pt / −1.5pt 是在本机菜单栏（30pt 高）上量出来的：⌘ 墨迹 12×11.5pt，
    /// 中心正好落在正中（18pt 时墨迹 13.5pt、顶出 22pt 画布，也太满）。
    private static let menuBarFontSize: CGFloat = 16
    private static let menuBarBaselineOffset: CGFloat = -1.5

    /// 菜单栏标题。字号与基线都要靠属性串带上，所以建栏与刷状态灯两处都得走这里
    /// （写 `button.title` 会把属性丢掉）。只给字体与基线、不给前景色：
    /// 颜色仍由按钮自己决定，才跟得上明暗壁纸与高亮态。
    private static func menuBarTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: menuBarFontSize),
            .baselineOffset: menuBarBaselineOffset,
        ])
    }

    private func buildMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.attributedTitle = Self.menuBarTitle("⌘⁴")
        let menu = NSMenu()
        // 菜单只放用户用得上的东西。自检、窗口顺序诊断是开发工具：
        // 前者走命令行 `--self-test`，后者启动时自动写文件，都不占菜单。
        menu.addItem(NSMenuItem(title: "配置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginItem = launchAtLogin
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshMenuBar()
    }

    /// 菜单栏图标兼当**权限状态灯**。
    ///
    /// 以前它不用承担这个：启动就弹配置窗，未授权时窗口顶上那条提示一定看得见。
    /// 现在开机自启那一次不弹窗了，没授权又没人告诉你的话，症状就是
    /// "开机的确启动了，按热键却什么都没发生"——只能靠图标自己说出来。
    private func refreshMenuBar() {
        guard let button = statusItem?.button else { return }
        let authorized = tap != nil
        button.attributedTitle = Self.menuBarTitle(authorized ? "⌘⁴" : "⌘⁴⚠️")
        button.toolTip = authorized
            ? "Chord：辅助功能已授权，快捷键可用"
            : "Chord：还缺辅助功能权限，快捷键不会生效 —— 点开菜单选「配置…」去授权"
    }

    // MARK: 权限

    /// 「去授权」：第一次触发系统弹窗（顺带把 Chord 登记进辅助功能列表），
    /// 之后弹窗不会再出现，只能直接打开设置面板。
    private func requestAccessibility() {
        if !didRequestPrompt {
            didRequestPrompt = true
            Accessibility.requestPrompt()
        } else {
            Accessibility.openSettingsPane()
        }
        watchForPermissionIfNeeded()
    }

    /// tap 没起来就一直轮询，直到授权。授权发生在「系统设置」里，我们只能回查。
    ///
    /// 不设超时：用户可能过很久才去授权，那时提示条应该照样自己消失。
    /// 每秒一次 AXIsProcessTrusted 的开销可以忽略。
    private func watchForPermissionIfNeeded() {
        guard tap == nil, permissionPoll == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, Accessibility.isTrusted else { return }
            timer.invalidate()
            self.permissionPoll = nil
            AppStatus.log("检测到授权，启动 tap")
            self.startHotkeyTap()
            self.refreshMenuBar()
            self.settings?.refreshPermissionBanner()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    /// 切换开机自启。
    ///
    /// 关键点：**调用没抛错不等于已生效** —— 系统可能把它挂成"等待批准"。
    /// 所以切换后一律回读 `status`，让菜单勾选态反映真实状态，而不是意图。
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        switch LaunchAtLogin.setEnabled(enable) {
        case .success:
            AppStatus.log("开机自启 → 请求\(enable ? "开启" : "关闭")，结果：\(LaunchAtLogin.description)")
        case .failure(let error):
            AppStatus.log("开机自启切换失败：\(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "\(enable ? "开启" : "关闭")开机自启失败"
            alert.informativeText = """
                \(error.localizedDescription)

                注意：登录项记的是这个 .app 的路径。开发构建在 build/ 下，
                把它移走会让登录项失效。
                """
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        // 回读真实状态
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
        if LaunchAtLogin.status == .requiresApproval {
            AppStatus.log("开机自启需要用户在「系统设置 → 通用 → 登录项」里批准")
        }
    }

    /// 把每个组里每个 app 的窗口顺序（含屏号/坐标/焦点）写到文件。
    ///
    /// 调用点：**启动后自动跑一次**（菜单项已移除）。为什么必须让 app 自己写：
    /// 读窗口需要辅助功能权限，而只有通过 open 启动的 app 有（TCC 按进程身份判定）。
    /// 自动跑意味着不必人工去点菜单——依赖人操作会把诊断卡在别人手上。
    private func writeWindowOrderDump() {
        var lines = [AppStatus.environmentSummary(), ""]
        for group in ConfigStore.shared.groups {
            lines.append("组 \(group.shortcutLabel)（\(group.apps.count) 个 app）")
            for app in group.apps {
                lines.append("  \(app.displayName)  运行中=\(app.isRunning)")
                for line in WindowEnumerator.describeOrder(of: app) {
                    lines.append("    " + line)
                }
            }
            lines.append("")
        }
        AppStatus.writeWindowOrder(lines.joined(separator: "\n") + "\n")
        AppStatus.log("已写入窗口顺序诊断（\(ConfigStore.shared.groups.count) 个组）")
    }

    // MARK: 窗口

    @objc private func showSettings() {
        // 记一笔"窗真的被弹出来了"：开机自启不弹窗这条行为在屏幕上看不见，
        // 只能靠日志区分"没弹"和"弹了但没注意到"。
        AppStatus.log("弹配置窗（这次启动来源=\(LaunchContext.origin.rawValue)）")
        if settings == nil {
            let controller = SettingsWindowController()
            controller.isHotkeyTapAvailable = { [weak self] in self?.tap != nil }
            controller.onAuthorize = { [weak self] in self?.requestAccessibility() }
            settings = controller
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        settings?.reload()
        NSApp.activate(ignoringOtherApps: true)
    }


    // MARK: tap

    private func startHotkeyTap() {
        guard tap == nil else { return }
        let created = HotkeyTap(level: .session, placement: .head, listenOnly: false)
        created.onReenabled = { reason in
            NSLog("Chord: tap 被系统禁用（\(reason)）→ 已重新启用")
        }
        created.onEvent = { [weak self] event in
            self?.route(event) ?? false
        }
        guard created.start() else {
            NSLog("Chord: CGEventTap 创建失败（辅助功能未授权？）")
            AppStatus.log("CGEventTap 创建失败 —— tapCreate 返回 nil")
            return
        }
        tap = created
        NSLog("Chord: CGEventTap 已启用")
        AppStatus.log("CGEventTap 已启用")
    }

    // MARK: 事件路由

    /// 返回 true = 吞掉该事件。
    private func route(_ event: HotkeyTap.KeyEvent) -> Bool {
        // 1. 录制期：配置窗优先，且把所有按键都吃掉（你在按键，不该同时打字）
        if let settings, settings.consumeWhileRecording(event) { return true }

        // 2. 正在切换
        if switcher.isActive { return routeWhileSwitching(event) }

        // 3. 空闲：看是不是某个组的热键
        guard event.type == .keyDown, !event.isRepeat else { return false }
        guard let group = matchingGroup(for: event) else { return false }

        enterGroup(group)
        return true
    }

    private func matchingGroup(for event: HotkeyTap.KeyEvent) -> GroupConfig? {
        let keyCode = UInt16(truncatingIfNeeded: event.keycode)
        let flags = GroupConfig.normalized(event.nsFlags)
        return ConfigStore.shared.groups.first {
            $0.hasRequiredModifier && $0.keyCode == keyCode && $0.modifiers == flags.rawValue
        }
    }

    // MARK: 切换

    private func enterGroup(_ group: GroupConfig) {
        guard let state = switcher.enter(group: group) else {
            NSSound.beep()          // 空组：按了什么都不会发生，给个声音
            return
        }
        activeModifiers = group.modifierFlags
        activeKeyCode = group.keyCode
        scheduleHUD(state)
        // 记一笔进入状态：我看不见 HUD，但可以从日志判断交互走到哪一步了。
        AppStatus.log("进入组 \(group.shortcutLabel) apps=\(state.apps.count) "
                      + "层=\(state.layer == .windows ? "windows" : "apps") "
                      + "窗口=\(state.windows.count) 高亮=\(state.layerIndex + 1)/\(state.layerCount)")
    }

    /// 延迟显示浮层。
    ///
    /// 按下就渲染的话，"按一下立刻松手打开默认 app"这条最常用的路径会闪一下浮层。
    /// 延迟 150ms：松手提交时把定时器取消，浮层从头到尾没出现过。
    /// 但**没有任何可选项**时（单 app 且它没有多窗口）不显示浮层，也不必延迟。
    private func scheduleHUD(_ state: GroupSwitcher.State) {
        hudShowTimer?.invalidate()
        hudShowTimer = nil

        if state.apps.count == 1, WindowEnumerator.windows(of: state.apps[0]).count <= 1 {
            return
        }

        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hudShowTimer = nil
            if let current = self.switcher.state { self.hud.show(current) }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudShowTimer = timer
    }

    /// 立即渲染（用户已经在选，需要反馈，不能再等）。
    private func showHUDNow() {
        hudShowTimer?.invalidate()
        hudShowTimer = nil
        if let state = switcher.state { hud.show(state) }
    }

    private func dismissHUD() {
        hudShowTimer?.invalidate()
        hudShowTimer = nil
        hud.hide()
    }

    private func commitSwitching() {
        dismissHUD()
        let action = switcher.commit()
        activeModifiers = []
        activeKeyCode = 0
        guard let action else { return }

        // 记下**实际走了哪条路**：「切过去跟没切一样」是屏幕上看不见的症状，
        // 有这一行就能从日志分辨是提了窗口、只激活，还是补了 reopen（`--status`）。
        let outcome: WindowEnumerator.ActivationOutcome
        switch action {
        case .activate(let app):
            outcome = WindowEnumerator.activate(app)
        case .raiseWindow(let app, let window):
            outcome = WindowEnumerator.activate(app, raising: window)
        }
        AppStatus.log("提交切换 action=\(action) 结果=\(outcome.rawValue)")
    }

    private func cancelSwitching() {
        dismissHUD()
        switcher.cancel()
        activeModifiers = []
        activeKeyCode = 0
    }

    /// 切换进行中的事件。
    ///
    /// 不变量：**循环键自身的抬起不提交**；提交只发生在和弦被打破时
    /// （任一修饰键抬起）。这条同时覆盖"先按组键再按修饰键"和"两键同时松开"。
    private func routeWhileSwitching(_ event: HotkeyTap.KeyEvent) -> Bool {
        // 修饰键状态变化 —— 和弦破了就提交。
        // 不吞这个事件：修饰键的真实状态该让系统知道。
        if event.type == .flagsChanged {
            if !event.nsFlags.isSuperset(of: activeModifiers) { commitSwitching() }
            return false
        }

        // 兜底：tap 被禁用过导致漏掉 flagsChanged 时，靠按键事件里的修饰键状态纠正。
        if event.type == .keyDown, !event.nsFlags.isSuperset(of: activeModifiers) {
            commitSwitching()
            return false
        }

        guard event.type == .keyDown, !event.isRepeat else {
            // 抬起循环键不提交，但要吞掉，免得前台 app 收到一个孤立的 keyUp。
            return event.type == .keyUp && UInt16(truncatingIfNeeded: event.keycode) == activeKeyCode
        }

        switch event.keycode {
        case 53:                                    // Esc
            AppStatus.log("Esc 取消切换")
            cancelSwitching()
            return true
        case 125:                                   // ↓ 下钻到窗口层
            if switcher.drillDown() != nil { showHUDNow() }
            return true
        case 126:                                   // ↑ 回 app 层
            if switcher.drillUp() != nil { showHUDNow() }
            return true
        default:
            break
        }

        // 再按一次组键 = 在当前层前进
        if UInt16(truncatingIfNeeded: event.keycode) == activeKeyCode,
           GroupConfig.normalized(event.nsFlags) == activeModifiers {
            switcher.advance()
            showHUDNow()
            return true
        }

        return false                                 // 别的键放行
    }
}

extension AppDelegate {
    /// 菜单要弹出来时刷新一次勾选态：用户可能在「系统设置」里改过，
    /// 只靠我们自己的切换动作去更新会显示成过期状态。
    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
    }
}
