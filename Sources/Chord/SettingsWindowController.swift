import Cocoa

// MARK: - 拖动载荷

extension NSPasteboard.PasteboardType {
    /// 拖动的是「某个组里的某个 app」，用 uuid + 下标定位。
    static let chordApp = NSPasteboard.PasteboardType("com.hiauhong.chord.app")
}

struct AppDragPayload {
    var groupID: UUID
    var index: Int

    var stringValue: String { "\(groupID.uuidString)#\(index)" }

    init(groupID: UUID, index: Int) {
        self.groupID = groupID
        self.index = index
    }

    init?(string: String) {
        let parts = string.split(separator: "#")
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[0])), let index = Int(parts[1]) else {
            return nil
        }
        self.groupID = uuid
        self.index = index
    }
}

// MARK: - 单个 app 图标（拖动源）

final class AppChipView: NSView, NSDraggingSource {

    /// 圆角背景单独一层：chip 自己不裁剪，否则角标会被切。
    private let background = NSView()
    private let imageView = NSImageView()
    /// 悬停时出现的删除角标。
    /// 之前只有右键菜单——功能是有的，但用户找不到，等于没有。
    private let removeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private(set) var app: AppRef?
    private(set) var groupID: UUID?
    private(set) var index: Int = 0
    private(set) var isMissing = false
    var onRemove: (() -> Void)?

    static let size: CGFloat = 40

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))

        // chip 自己**不裁剪子视图**。
        // 注意：AppKit 给 layer-backed 的 NSView **默认就把 masksToBounds 设成 true**
        // （UIKit 恰好相反，默认 false）。所以只要不显式关掉，任何探出 chip 的子视图
        // 都会被切掉一块——这正是"删除角标显示不全"的根因，跟圆角无关。
        // 圆角仍由下面的 background 子视图负责，它只裁自己。
        wantsLayer = true
        layer?.masksToBounds = false
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        // 常态**不画边框**：它不承担功能，只是视觉噪音。
        // 边框只在需要传递状态时出现，见 configure 与 flash。
        background.layer?.borderWidth = 0
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        removeButton.title = ""
        removeButton.imageScaling = .scaleProportionallyUpOrDown
        // 用符号自带的圆（xmark.circle.fill），而不是自己画圆角矩形：
        // 自己画的那版要假设 frame 与圆角半径的关系，而 NSButton 的 frame 会比
        // 约束值高几个点（cell 内边距），于是圆角算错、还探出 chip 边界被父视图裁掉。
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "移除")
        removeButton.contentTintColor = .systemRed
        removeButton.isHidden = true
        removeButton.target = self
        removeButton.action = #selector(removeSelf)
        removeButton.toolTip = "从这一组移除"

        addSubview(imageView)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 32 而不是更小：app 图标自带约 10% 的透明边，太小会比旁边的「+」空位显得还轻。
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),

            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
            // 角标跨在 chip 右上角上（就是最初的位置）。
            // 它探出 chip 边界，所以必须配合两件事（两件都已处理）：
            //   1. chip 自己不能裁子视图 —— `masksToBounds = false`，见 init；
            //   2. 悬停判定区要放大，否则鼠标移到探出的那部分会被判成"离开"，
            //      角标闪一下就点不到。
            // 注意 AppKit 这几条锚点的正数方向是**向下**，与视图自身的 y 轴相反。
            removeButton.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            removeButton.centerYAnchor.constraint(equalTo: topAnchor, constant: 2),
        ])

        toolTip = ""
    }

    /// 供渲染诊断用：把角标显示出来（正常只在鼠标悬停时出现）。
    func showRemoveBadgeForDiagnostics() { removeButton.isHidden = false }

    /// 命中判定：除角标外一律命中 chip 自己。
    /// 图标那层是 NSImageView；如果让它成为"起手视图"，点击就落在它身上而不是 chip，
    /// 手势归谁就取决于 NSImageView 的内部实现——让 chip 自己接管命中，起手才是确定的。
    /// 但**光有命中还不够**：`mouseDown` 也必须在 chip 这里止住，见下面「拖动」一节。
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 注意：point 在**父视图坐标系**里，不是自己的 bounds —— 上一版这里搞错了。
        guard let hit = super.hitTest(point) else { return nil }
        if hit === removeButton { return hit }
        // 图标的 NSImageView 会截走事件；一律换成 chip 自己，保证拖动由 chip 起手。
        return self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func configure(app: AppRef, groupID: UUID, index: Int) {
        self.app = app
        self.groupID = groupID
        self.index = index
        imageView.image = app.icon

        // 路径失效（app 被删或改名）要看得出来，否则点下去只会静默失败。
        isMissing = !FileManager.default.fileExists(atPath: app.path)
        // 常态无框；路径失效时才有红框——没有常态边框，异常反而更醒目。
        background.layer?.borderWidth = isMissing ? 1 : 0
        background.layer?.borderColor = isMissing ? NSColor.systemRed.cgColor : NSColor.separatorColor.cgColor

        if isMissing {
            toolTip = "\(app.displayName)（已失效：路径不存在 —— \(app.path)）"
        } else {
            let state = app.isRunning ? "运行中" : "未运行"
            toolTip = "\(app.displayName)（\(state)）· 拖动可排序或换组 · 悬停点 × 移除"
        }
    }

    /// 三种状态在视觉上分开：失效（最暗 + 红框）／未运行（暗）／运行中（正常）。
    /// HUD 上也要用这个区分「激活」与「启动」。
    func refreshRunningState() {
        alphaValue = isMissing ? 0.3 : ((app?.isRunning ?? false) ? 1.0 : 0.55)
    }

    // MARK: 悬停显示删除角标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // 判定区比 chip 大一圈：角标探出边界，鼠标移到它上面时不能算"离开"，
        // 否则角标会闪一下就点不到。这圈余量同时也是抖动缓冲。
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -10, dy: -10),
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { removeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { removeButton.isHidden = true }

    // MARK: 右键菜单（也用 menu(for:)，它同时覆盖 control-点击）

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let app else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "移除 \(app.displayName)", action: #selector(removeSelf), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        if isMissing {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "路径已失效", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        return menu
    }

    @objc private func removeSelf() { onRemove?() }

    /// 短暂高亮这个图标。用途：往组里加一个**已经在本组**的 app 时，
    /// 图标数不会变，光看界面像"没反应"——把已有的那个闪一下就是反馈。
    func flash() {
        background.layer?.borderWidth = 2
        background.layer?.borderColor = NSColor.controlAccentColor.cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.background.layer?.borderWidth = self.isMissing ? 1 : 0
            self.background.layer?.borderColor =
                (self.isMissing ? NSColor.systemRed : NSColor.separatorColor).cgColor
        }
    }

    // MARK: 拖动

    /// 鼠标按下。**绝对不调 super** —— 这是"图标拖不动"的根因所在。
    ///
    /// `NSResponder` 给 `mouseDown` 的默认实现是「沿响应链上交」，于是这一下点击会冒泡到
    /// 外层 `NSTableView`，表格立刻进入自己的选择跟踪循环（内部 `nextEventMatchingMask`），
    /// 把后续的 `mouseDragged` 全部吃掉：`AppChipView` 永远等不到拖动，拖动会话从来没起手过。
    /// 表现就是按住图标拖、毫无反应（连跟手的拖动影像都没有）。
    ///
    /// 代价是行选中也一并被"不上交"了，所以这里自己补一次选中：
    /// 点图标仍要选中它所在那一行（底部「删除选中组」依赖 `selectedRow`）。
    override func mouseDown(with event: NSEvent) {
        selectEnclosingRow()
        // 空 chip 没有可拖的东西，选中就够了。
        guard groupID != nil, app != nil else { return }
        guard let dragEvent = dragEventStartingAt(event) else { return }
        beginDrag(with: dragEvent)
    }

    /// 自己跟踪手势：返回「触发拖动的那次鼠标事件」；松手前没动就返回 nil（算一次点击）。
    ///
    /// 抽成独立方法是为了能被合成事件驱动着测（见 `--drag-mouse-test`）——
    /// 真起一个拖动会话会进 CoreDrag，测试里没法收场。
    func dragEventStartingAt(_ event: NSEvent) -> NSEvent? {
        let start = convert(event.locationInWindow, from: nil)
        // 系统自己的拖动阈值也在 3pt 上下：低于它算点击，免得手一抖就把图标甩出去。
        let threshold: CGFloat = 3
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return nil }
            let point = convert(next.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) >= threshold { return next }
        }
        return nil
    }

    /// 点图标 = 选中它所在的行。表格默认会做，但这只手势已经不再上交给它，得自己补。
    private func selectEnclosingRow() {
        guard let table = enclosingTableView else { return }
        let row = table.row(for: self)
        guard row >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// 向上找外层表格：chip → AppStripView → AppsCellView → NSTableRowView → NSTableView。
    private var enclosingTableView: NSTableView? {
        var view: NSView? = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }

    private func beginDrag(with event: NSEvent) {
        guard let groupID, app != nil else { return }
        let payload = AppDragPayload(groupID: groupID, index: index)

        let item = NSPasteboardItem()
        item.setString(payload.stringValue, forType: .chordApp)

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}

// MARK: - 一行里的 app 条（拖动目标）

final class AppStripView: NSStackView {

    /// 落下时回调：源组、源下标、插入位置。
    var onDrop: ((UUID, Int, Int) -> Void)?
    private var currentGroupID: UUID?

    /// 拖动时显示"会插到这里"的竖线。
    /// 没有它的话，拖动过程里**看不出会落到哪**——放下之前一切都是隐形的，
    /// 用户只会觉得"好像不能拖"。
    private let insertionIndicator = NSView()

    /// 图标之间的间距。快捷键列那种"按内容算宽度"要用到它，所以提成常量。
    static let chipSpacing: CGFloat = 8

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Self.chipSpacing
        registerForDraggedTypes([.chordApp])

        // 注意：它是普通子视图，**不是 arrangedSubview**，
        // 否则会被 stack 当成一个图标参与排布。
        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.layer?.cornerRadius = 1
        insertionIndicator.isHidden = true
        addSubview(insertionIndicator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func setGroupID(_ id: UUID) { currentGroupID = id }

    /// 把鼠标横坐标换算成插入下标（在**含被拖项**的原数组里的插入位置）。
    func insertionIndex(for point: NSPoint) -> Int {
        for (index, view) in arrangedSubviews.enumerated() {
            let frame = convert(view.bounds, from: view)
            if point.x < frame.midX { return index }
        }
        return arrangedSubviews.count
    }

    /// 显示插入位置指示线。
    func showInsertionIndicator(at index: Int) {
        let chips = arrangedSubviews
        let x: CGFloat
        if chips.isEmpty {
            x = 0
        } else if index < chips.count {
            x = chips[index].frame.minX - spacing / 2
        } else {
            x = chips[chips.count - 1].frame.maxX + spacing / 2
        }
        insertionIndicator.frame = NSRect(x: x - 1, y: 4, width: 2, height: max(0, bounds.height - 8))
        insertionIndicator.isHidden = false
    }

    func hideInsertionIndicator() { insertionIndicator.isHidden = true }

    /// 供渲染诊断用：强制定位并显示指示线。
    func showInsertionIndicatorForDiagnostics(at index: Int) {
        layoutSubtreeIfNeeded()
        showInsertionIndicator(at: index)
    }

    // MARK: 收放

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        showInsertionIndicator(at: insertionIndex(for: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideInsertionIndicator() }

    override func draggingEnded(_ sender: NSDraggingInfo) { hideInsertionIndicator() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideInsertionIndicator() }
        guard let raw = sender.draggingPasteboard.string(forType: .chordApp),
              let payload = AppDragPayload(string: raw) else { return false }
        return handleDrop(payload: payload, at: convert(sender.draggingLocation, from: nil))
    }

    /// 落点处理。从 `performDragOperation` 里抽出来，这样它**不依赖 AppKit 的拖动机制**
    /// 就能被测试（见 `Chord --drag-test`）。
    @discardableResult
    func handleDrop(payload: AppDragPayload, at point: NSPoint) -> Bool {
        guard let onDrop else { return false }
        onDrop(payload.groupID, payload.index, insertionIndex(for: point))
        return true
    }
}

// MARK: - 快捷键录制按钮

final class HotkeyRecorderButton: NSButton {

    private(set) var isRecording = false
    private var label: String = "点击录制"
    private var transientTimer: Timer?
    /// 录制中已按下、但还没提交的组合。
    private var pendingLabel: String?
    /// 正在显示的临时消息（例如"第 2 组已占用"）。
    private var transientText: String?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    /// 清除绑定（把组变回"未绑定"）。只有已绑定时才在菜单里出现。
    var onClear: (() -> Void)?
    private var hasBinding: Bool { label != "点击录制" }

    /// 按钮宽度**按这一行实际的快捷键**算，而不是按"最长可能"算。
    ///
    /// 默认档键帽的可用宽度 = 按钮宽 − 18（左右各 8 内缩 + 1pt 底色 + 1pt 余量），
    /// 所以给这个组合留 2pt 余量即可：按钮 = 这个组合的键帽宽 + 20。
    ///
    /// 下限 70：未绑定态的「点击录制」和录制中的那几行提示要放得下。
    /// 上限 106：三键组合里最宽的 ⌥⌘F12 / ⌥⌘Esc（87pt）正好放得下；
    /// 更长的组合不再撑宽按钮，而是交给 `keycapTiers` 逐级缩小。
    ///
    /// 曾经是固定的 132：为了"⌃⌥⌘F12 这类**四键**组合的默认档也放得下"，
    /// 结果常规的 ⌘1（49pt）只用掉三分之一，列右边空出一大片。
    static func width(forShortcutWidth shortcutWidth: CGFloat) -> CGFloat {
        min(106, max(70, shortcutWidth + 20))
    }

    /// 宽度约束留着，好在 `configure` 里按这一行的快捷键调整。
    private var widthConstraint: NSLayoutConstraint?

    func setWidth(_ width: CGFloat) {
        widthConstraint?.constant = width
    }

    static func make() -> HotkeyRecorderButton {
        let button = HotkeyRecorderButton()
        // 不用系统 bezel，自己画：已绑定时显示成键帽，而不是一块灰色大按钮。
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        let width = button.widthAnchor.constraint(equalToConstant: Self.width(forShortcutWidth: 0))
        width.isActive = true
        button.widthConstraint = width
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.toolTip = "点击录制快捷键；右键可清除绑定"
        return button
    }

    func show(shortcut: String?) {
        label = shortcut ?? "点击录制"
        // 宽度跟着**这一行的快捷键**走：⌘1 的悬停底色就只包住 ⌘1，不再拖一整条空底色。
        // 放在这里而不是让 cell 调用，是为了只有一处决定宽度 —— --render-recorder
        // 也是走 show()，渲出来的宽度才和真表格一致。
        setWidth(Self.width(forShortcutWidth: shortcut.map {
            Keycaps.size(of: Keycaps.tokens(of: $0), style: Keycaps.Style()).width
        } ?? 0))
        refreshTitle()
    }

    func beginRecording() {
        isRecording = true
        pendingLabel = nil
        refreshTitle()
    }

    /// 显示**待定**组合：还是录制态（橙色），但已经把按下的组合显示出来。
    /// 用不同色调区分"待定"和"已绑定"，人才敢继续按键改。
    func showPending(_ text: String) {
        pendingLabel = text
        refreshTitle()
    }

    func endRecording() {
        isRecording = false
        pendingLabel = nil
        refreshTitle()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // 录制中不给菜单：此时唯一的出路是 Esc 取消，不该混进"清除绑定"。
        guard !isRecording else { return nil }

        let menu = NSMenu()
        let record = NSMenuItem(title: hasBinding ? "重新录制" : "录制快捷键",
                                action: #selector(recordSelf), keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        if hasBinding {
            let clear = NSMenuItem(title: "清除绑定", action: #selector(clearSelf), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        return menu
    }

    @objc private func recordSelf() { performClick(nil) }

    @objc private func clearSelf() { onClear?() }

    /// 在按钮自己身上短暂显示一条消息（例如"第 2 组已占用"），随后恢复。
    /// 录制失败的原因必须让人看见，而答案就该出现在他正在盯着按键的那个控件上——
    /// 而不是另起一行状态文字。录制中恢复后仍回到"按下组合键…"。
    func showTransientMessage(_ text: String) {
        transientTimer?.invalidate()
        transientText = text
        title = text
        needsDisplay = true

        let timer = Timer(timeInterval: 1.8, repeats: false) { [weak self] _ in
            self?.transientTimer = nil
            self?.transientText = nil
            self?.refreshTitle()
        }
        RunLoop.main.add(timer, forMode: .common)
        transientTimer = timer
    }

    /// `title` 仍然维护（无障碍读的是它），但画面由 `draw` 负责。
    private func refreshTitle() {
        title = isRecording ? (pendingLabel ?? "按下组合键…") : label
        needsDisplay = true
    }

    // MARK: 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    // MARK: 绘制
    //
    // 四种外观，各自只用一种颜色说话：
    //   已绑定 → 键帽，无底（悬停才出现浅底，提示"可点"）
    //   未绑定 → 虚线框 + 灰字（一个等着被填的空位）
    //   录制中 → 橙色描边；按下的待定组合以橙色键帽显示
    //   出错   → 红色描边 + 红字，1.8 秒后恢复

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 1, dy: 2)
        let path = NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)

        if let transientText {
            fill(path, stroke: .systemRed)
            drawCentered(transientText, color: .systemRed, size: 11)
        } else if isRecording {
            fill(path, stroke: .systemOrange)
            if let pendingLabel {
                drawKeycaps(Keycaps.tokens(of: pendingLabel), tint: .systemOrange, in: pill)
            } else {
                drawCentered("按下组合键…", color: .systemOrange, size: 12)
            }
        } else if hasBinding {
            if isHighlighted || isHovered {
                NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
                path.fill()
            }
            drawKeycaps(Keycaps.tokens(of: label), tint: nil, in: pill)
        } else {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : (isHovered ? 0.05 : 0)).setFill()
            path.fill()
            let dashed = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            dashed.lineWidth = 1
            dashed.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            dashed.stroke()
            drawCentered(label, color: .secondaryLabelColor, size: 12)
        }
    }

    private func fill(_ path: NSBezierPath, stroke color: NSColor) {
        color.withAlphaComponent(0.12).setFill()
        path.fill()
        color.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// 居中画一行字。**放不下就缩字号**：撞车提示里带着被占用的那个组合
    /// （「⌃⌥⌘F12 第 2 组占用」），按钮收窄之后不缩就会被裁掉半个字。
    /// 下限 8pt：再小就不如让调用方改文案了。
    private func drawCentered(_ text: String, color: NSColor, size: CGFloat) {
        var fontSize = size
        var string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color,
        ])
        let available = bounds.width - 8
        while fontSize > 8, string.size().width > available {
            fontSize -= 1
            string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: color,
            ])
        }
        let textSize = string.size()
        string.draw(at: NSPoint(x: bounds.midX - textSize.width / 2,
                                y: bounds.midY - textSize.height / 2))
    }

    /// 键帽左边缘距按钮左边缘的距离（1pt 底色余量 + 8pt 内边距）。
    /// 所在的 cell 用它把按钮往左挪，让键帽与列名对齐。
    static let keycapInset: CGFloat = 9

    /// 键帽靠左排：和右边那列图标一样从左边读起，列与列之间才对得齐。
    ///
    /// 放不下就**逐级换小一号**（字号、键帽高、内缩一起缩），而不是让按钮边裁掉它。
    /// 三档的数值是拿实测宽度定的（`--render-recorder` 会把每一档都渲出来）：
    /// ⌘1 49pt、⌘⇧4 76pt、⌃⌥⌘F12 113pt（默认档放不下 → 第二档 86pt）、
    /// ⌃⌥⇧⌘F12 140pt（前两档都放不下 → 第三档 82pt）。
    private static let keycapTiers: [(font: CGFloat, height: CGFloat, spacing: CGFloat,
                                     padding: CGFloat, inset: CGFloat)] = [
        (12, 22, 3, 12, 8),
        (10, 18, 2, 8, 4),
        (9, 14, 1, 5, 4),
    ]

    private func drawKeycaps(_ tokens: [String], tint: NSColor?, in rect: NSRect) {
        var style = Keycaps.Style(tint: tint)
        var inset = Self.keycapTiers[0].inset
        for (index, tier) in Self.keycapTiers.enumerated() {
            let candidate = Keycaps.Style(fontSize: tier.font, height: tier.height,
                                          spacing: tier.spacing, padding: tier.padding, tint: tint)
            style = candidate
            inset = tier.inset
            let fits = Keycaps.size(of: tokens, style: candidate).width <= rect.width - inset * 2
            if fits || index == Self.keycapTiers.count - 1 { break }
        }
        let size = Keycaps.size(of: tokens, style: style)
        Keycaps.draw(tokens, at: NSPoint(x: rect.minX + inset, y: rect.midY - size.height / 2), style: style)
    }
}

// MARK: - 「添加 app」空位

/// 和 app 图标同样大小的虚线空位：看起来就是"这一排的下一格"，
/// 而不是一个另起风格的圆形按钮。
final class AddAppButton: NSButton {

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: AppChipView.size, height: AppChipView.size))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        setAccessibilityLabel("添加 app")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AppChipView.size),
            heightAnchor.constraint(equalToConstant: AppChipView.size),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let active = isHovered || isHighlighted
        let color: NSColor = active ? .controlAccentColor : .tertiaryLabelColor

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if active {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.18 : 0.08).setFill()
            path.fill()
        }
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        color.setStroke()
        path.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let target = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        // 模板符号要染色：先画形状，再用 sourceAtop 把颜色盖上去
        let tinted = NSImage(size: size, flipped: false) { frame in
            symbol.draw(in: frame)
            color.set()
            frame.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: target)
    }
}

// MARK: - 两列：快捷键 | APP
//
// 拆成两个 NSTableCellView（而不是一个"整行"视图）是为了让列名由 NSTableView
// 的表头提供并对齐——手写两个标签去凑单元格内部控件的缩进，是靠不住的。

/// 左列：这一组的快捷键。
final class ShortcutCellView: NSTableCellView {

    let recorder = HotkeyRecorderButton.make()
    var onRecord: (() -> Void)?
    var onClearShortcut: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        recorder.target = self
        recorder.action = #selector(recordTapped)
        recorder.onClear = { [weak self] in self?.onClearShortcut?() }
        recorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recorder)

        // 录制按钮往左探出：键帽画在按钮内边距之后，不探出的话键帽会比
        // 列名「快捷键」缩进 9pt，看起来没对齐。
        // 探出去的只是悬停/录制时的底色，所以 cell 不能裁子视图（layer 默认会裁）。
        wantsLayer = true
        layer?.masksToBounds = false

        NSLayoutConstraint.activate([
            recorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2 - HotkeyRecorderButton.keycapInset),
            recorder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    @objc private func recordTapped() { onRecord?() }

    func configure(group: GroupConfig,
                   isRecording: Bool,
                   onRecord: @escaping () -> Void,
                   onClearShortcut: @escaping () -> Void) {
        self.onRecord = onRecord
        self.onClearShortcut = onClearShortcut
        recorder.show(shortcut: group.hasRequiredModifier ? group.shortcutLabel : nil)
        if isRecording { recorder.beginRecording() } else { recorder.endRecording() }
    }
}

/// 右列：这一组的 app。
final class AppsCellView: NSTableCellView {

    let strip = AppStripView()
    private let addButton = AddAppButton()
    var onAddApp: (() -> Void)?
    var onRemoveApp: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addButton.target = self
        addButton.action = #selector(addAppTapped)
        addButton.toolTip = "往这一组添加 app"

        for subview in [strip, addButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            strip.centerYAnchor.constraint(equalTo: centerYAnchor),
            strip.heightAnchor.constraint(equalToConstant: AppChipView.size),

            addButton.leadingAnchor.constraint(equalTo: strip.trailingAnchor, constant: 8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    @objc private func addAppTapped() { onAddApp?() }

    /// 让某个已在组里的 app 图标闪一下（重复添加时的反馈）。
    func flashApp(_ app: AppRef) {
        for case let chip as AppChipView in strip.arrangedSubviews
        where chip.app?.isSameApp(as: app) == true {
            chip.flash()
        }
    }

    /// 重建这一列的 app 图标。每次 reload 都走这里，所以闭包也在这里重新绑定。
    func configure(group: GroupConfig,
                   onAddApp: @escaping () -> Void,
                   onRemoveApp: @escaping (Int) -> Void) {
        self.onAddApp = onAddApp
        self.onRemoveApp = onRemoveApp

        strip.setGroupID(group.id)

        for view in strip.arrangedSubviews {
            strip.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, app) in group.apps.enumerated() {
            let chip = AppChipView()
            chip.configure(app: app, groupID: group.id, index: index)
            chip.refreshRunningState()
            chip.onRemove = { [weak self] in self?.onRemoveApp?(index) }
            strip.addArrangedSubview(chip)
        }
    }
}

// MARK: - 表头标题的内缩

/// 表头标题左内缩可控的版本。
///
/// 系统默认只给标题留约 4pt，而 APP 列的第一个图标是从更右边才看得见的
/// （2pt 条内缩 + 图标在 40pt chip 里居中又内缩 4pt + app 图标自带约 10% 画布留白），
/// 于是「APP」看着比图标靠左一截。这个 cell 把标题推到与图标**可见左边缘**同一条竖线上。
///
/// 为什么不是"把图标条往左挪"（快捷键那列就是这么干的）：图标条再往左，chip 的悬停
/// 角标和选中底色就会被 cell 裁掉；而且图标自身那圈透明留白没法靠挪动消掉。
final class InsetHeaderCell: NSTableHeaderCell {

    /// 标题左边缘距列左边缘的距离。
    var leadingInset: CGFloat = 4

    /// 注意：不能只重写 `titleRect(forBounds:)`——实测那个方法在现在的 AppKit 里
    /// **根本不会被调用**（打印验证过），标题是 `drawInterior` 自己算位置画的。
    /// 所以这里把画标题的 frame 右移。
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = cellFrame
        frame.origin.x += leadingInset
        frame.size.width = max(0, frame.width - leadingInset)
        super.drawInterior(withFrame: frame, in: controlView)
    }
}

// MARK: - 选中行的底色

/// 表格选中行的底色：**强调色的浅色版**，不是系统那身深蓝。
///
/// 系统默认的 `selectedContentBackgroundColor` 是一块饱和的深蓝，铺满 60pt 高的整行之后
/// 比行里的内容（快捷键键帽、app 图标）还抢眼——要看的恰恰是内容，不是"哪一行被选中了"。
/// 换成浅色版：一眼看得出选中，但视线还是落在键帽和图标上。
///
/// `isEmphasized` 锁死 false 是配套的另一半：深色底上 AppKit 会把单元格里的文字翻成白色，
/// 浅色底上那样就等于看不见。锁成 false 让它保持正常的深色文字。
final class LightSelectionRowView: NSTableRowView {

    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, selectionHighlightStyle != .none else { return }
        // 留 2pt 边：整行铺满会贴着卡片边框，缩一点才像"选中了一块"而不是"刷了底色"。
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        path.fill()
    }
}

// MARK: - 权限提示条

/// 未授权辅助功能时，显示在配置窗顶部的提示条。
///
/// 权限提示放在主窗口而不是单独的引导窗：用户打开 Chord 看到的就是它，
/// 授权完成后提示条自己消失，不需要关窗、也不需要理解"自检"是什么。
final class PermissionBannerView: NSView {

    var onAuthorize: (() -> Void)?
    private let background = NSView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 1
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "需要权限")
        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "需要辅助功能权限，快捷键才会生效")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        // 第二句专门覆盖"明明勾选了却没用"：重新构建后签名变了，旧条目会失效
        let detail = NSTextField(wrappingLabelWithString:
            "在系统设置里勾选 Chord。已经勾选却没生效？删掉那一条再重新添加。授权后这里会自动消失。")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let button = NSButton(title: "去授权", target: self, action: #selector(authorizeTapped))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"          // 默认按钮（强调色）：这是窗口里此刻最该点的东西
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, texts, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        refreshColors(emphasized: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    @objc private func authorizeTapped() { onAuthorize?() }

    /// 未授权时点录制：不再弹模态框，而是让这条提示闪一下——答案已经在窗口里了。
    func flash() {
        refreshColors(emphasized: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.refreshColors(emphasized: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors(emphasized: false)
    }

    private func refreshColors(emphasized: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(emphasized ? 0.28 : 0.12).cgColor
            background.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(emphasized ? 0.9 : 0.35).cgColor
        }
    }
}

// MARK: - 列表外框

/// 圆角卡片样式的滚动视图。单独成类只为一件事：边框色是 CGColor，
/// 不会自己跟着深浅色切换，得在外观变化时重新取一次。
final class CardScrollView: NSScrollView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorderColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshBorderColor()
    }

    private func refreshBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

// MARK: - 配置窗

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    /// 配置来源。可注入：自测（--record-test）需要一个临时配置，
    /// 绝不能拿真实配置做实验。
    var store: ConfigStore = .shared {
        didSet { store.onChange = { [weak self] in self?.reload() } }
    }
    private var tableView: NSTableView!
    private var removeGroupButton: NSButton!
    private var addGroupButton: NSButton!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var permissionBanner: PermissionBannerView!
    /// 表格顶边的两种挂法：有提示条时挂在它下面，没有时挂在窗口顶上。
    private var scrollTopToContent: NSLayoutConstraint!
    private var scrollTopToBanner: NSLayoutConstraint!
    private var didReportLoadFailure = false
    /// 权限提示条自己的约束（顶边 + 左右）。显隐时要整组开关，见 refreshPermissionBanner。
    private var permissionBannerConstraints: [NSLayoutConstraint] = []

    /// 正在录制的组下标（nil = 没在录）。
    private(set) var recordingRow: Int?

    /// 录制中已按下、但**还没落盘**的组合。
    ///
    /// 有了它，"按错了"才救得回来：按住修饰键期间后续按键只是替换待定值，
    /// 松手（和弦破了）才提交——和组热键那条"和弦破坏时提交"的不变量一致。
    private var pendingShortcut: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)?
    /// 上一次因撞车被拒的组合。同一个组合**再按一次 = 交换**两组。
    private var lastRejected: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)?

    /// 配置窗尺寸的 autosave 键名。**诊断命令要按名字清它** ——
    /// 裸二进制没有 bundle id，`UserDefaults` 落在 `Chord` 域（和 .app 的
    /// com.hiauhong.chord 不是同一个），那里可能留着上一次量尺寸写进去的陈旧尺寸，
    /// 一创建窗口就套上了（这个坑咬过两次）。
    static let frameAutosaveName = "ChordSettingsWindow.v7"

    /// 全局 tap 是否可用（未授权时为 false，此时拒绝进入录制、并显示权限提示条）。
    var isHotkeyTapAvailable: (() -> Bool)?
    /// 点提示条上的「去授权」。
    var onAuthorize: (() -> Void)?

    // MARK: 宽度（都按内容算，不写死常数）

    /// 一个组合的键帽排出来有多宽（未绑定 = 0）。
    static func shortcutWidth(of group: GroupConfig) -> CGFloat {
        guard group.hasRequiredModifier else { return 0 }
        return Keycaps.size(of: Keycaps.tokens(of: group.shortcutLabel), style: Keycaps.Style()).width
    }

    /// 快捷键列的宽度：按**当前配置里最宽的那个快捷键**定。
    ///
    /// 上下限：88 是下限（未绑定态的「点击录制」和那几行提示要放得下）；
    /// 124 是上限（三键组合里最宽的 ⌥⌘F12 / ⌥⌘Esc = 87pt 加上左右边距正好）；
    /// 更长的组合不再撑列，交给 `keycapTiers` 逐级缩小。
    /// 于是"只绑了 ⌘1..⌘5"的配置不会为 ⌃⌥⇧⌘F12 白留一整段宽度。
    static func shortcutColumnWidth(for groups: [GroupConfig]) -> CGFloat {
        let widest = groups.map { shortcutWidth(of: $0) }.max() ?? 0
        return min(124, max(88, widest + 38))
    }

    /// APP 列的宽度：按**最长那一行**实际需要的宽度算，不是按"每个 app 48pt"估。
    ///
    /// 每一项都和 `AppsCellView` 里的约束一一对应：图标条从 cell 左边 2pt 起、
    /// 条与 ⊕ 相隔 8pt、⊕ 宽 40pt（和图标等大）、右边留 4pt。
    /// 于是最长那一行的 ⊕ 正好距列右端 4pt，短的那些行右边留白（表格列只有一种宽度）。
    static func appsColumnWidth(for groups: [GroupConfig]) -> CGFloat {
        // 至少按 3 个算：只放 1~2 个时窗口会显得空
        let widest = max(3, groups.map(\.apps.count).max() ?? 3)
        let strip = CGFloat(widest) * AppChipView.size
            + CGFloat(widest - 1) * AppStripView.chipSpacing
        return 2 + strip + 8 + AppChipView.size + 4
    }

    /// 窗口宽度 = 两列的宽度 + 表格/卡片的边距。
    /// 81 是实测反推的"两列之外"的部分（滚动视图 16×2 的内边距、卡片边框、表格 .inset 内边距）。
    /// 两列的宽度**都是算出来的**，所以窗口宽度也就跟着内容走 ——
    /// 加一个 app、或录一个更长的快捷键，窗口（和最小宽度）都会跟着长。
    static func defaultWidth(apps: [GroupConfig], columnWidth: CGFloat) -> CGFloat {
        81 + columnWidth + appsColumnWidth(for: apps)
    }

    convenience init() {
        // 窗口宽度由两列的内容决定：APP 列按"最长那一行的 app 数"（至少 3 个），
        // 快捷键列按"配置里最宽的那个快捷键"（见 shortcutColumnWidth）。
        let groups = ConfigStore.shared.groups
        let columnWidth = Self.shortcutColumnWidth(for: groups)
        let defaultWidth = Self.defaultWidth(apps: groups, columnWidth: columnWidth)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Chord 配置"
        window.center()
        // 换了 autosave 名字：否则旧的已保存尺寸会盖掉新默认值，改了等于没改。
        // v4：换名字是为了让新默认宽度生效 —— 用户已经拖过的旧尺寸会盖掉代码里的默认值。
        // v5：同上（快捷键列 150 → 124）。
        // v6：同上（列宽改为按配置自适应，421 → 355）。
        // v7：同上（APP 列也按内容算，窗口 355 → 359）。
        window.setFrameAutosaveName(Self.frameAutosaveName)
        // 最小宽度 = 默认宽度：再窄下去图标条会被压缩（实测 380pt 时条宽 133、
        // 350pt 时 107，图标肉眼可见被挤扁），那比"窗口不能更窄"更糟。
        window.minSize = NSSize(width: defaultWidth, height: 240)
        self.init(window: window)
        // 录制态的出口**必须包含"窗没了"**：录制中的每个 keyDown/keyUp/修饰键事件
        // 都会被全局吞掉（见 consumeWhileRecording），而它原先只有 Esc / 松手提交 /
        // 撞车交换三条出口。点完录制按钮直接关窗（或切到别的 app），录制态就永远留着，
        // 症状是整台机器的键盘像死了 —— 2026-09-30 实际踩到，靠 HID/session 双层
        // 差分探针定位：HID 收得到按键、session 收到 0 个。
        window.delegate = self
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidResignActive),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)
        buildUI()
        store.onChange = { [weak self] in self?.reload() }
    }

    // MARK: 界面

    private func buildUI() {
        guard let window else { return }
        let content = NSView()

        tableView = NSTableView()
        // 角标探出 chip 约 8pt，而 cell 是会裁剪的（masksToBounds 默认 true），
        // 所以行高要比 chip 高出一个余量，否则角标的透明内边距会被 cell 顶掉。
        // 40(chip) + 2×8(角标外探) + 余量 = 60。
        tableView.rowHeight = 60
        tableView.style = .inset
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        // 两列各有列名，所以顶部的说明行不需要了。
        tableView.headerView = NSTableHeaderView()

        let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutColumn.title = "快捷键"
        // 列宽按**配置里最宽的那个快捷键**定（reload 里会随配置变化重算）。
        // 按钮比 cell 左边缘探出 7pt（让键帽与列名对齐），右边留 11pt 余量。
        shortcutColumn.width = Self.shortcutColumnWidth(for: store.groups)
        shortcutColumn.minWidth = 88
        shortcutColumn.maxWidth = 200
        shortcutColumn.resizingMask = []
        tableView.addTableColumn(shortcutColumn)

        let appsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("apps"))
        // 初始宽度按内容算；之后窗口被手动拉宽时由这一列吸收（resizingMask = .autoresizingMask）
        appsColumn.width = Self.appsColumnWidth(for: store.groups)
        // 标题左内缩到和图标可见左边缘对齐（默认那点内缩会让「APP」看着没对齐）。
        // 8 是拿 `--render-window` 渲出来量出来的：改之前标题 ink 在 201.5pt、
        // 图标可见左边缘在 208~210.5pt；8pt 让两者落在同一条竖线上（±1pt）。
        let appsHeader = InsetHeaderCell()
        appsHeader.alignment = .left
        appsHeader.leadingInset = 8
        appsColumn.headerCell = appsHeader
        appsColumn.title = "APP"
        // 允许收窄到"2 个图标"的宽度；原来卡在 200 会让窗口窄不下去
        // （量出来：窄于 420pt 后列不再收缩，右侧空隙固定 31pt）。
        appsColumn.minWidth = 120
        appsColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(appsColumn)

        let scroll = CardScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // 圆角卡片 + 一圈细线，代替老式的凹陷边框（bezelBorder）。
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollView = scroll

        // 用 SF Symbol 而不是 +/− 文本字形：矢量图标在任何状态（含禁用态）都完整、
        // 且系统会自动做状态着色。文本字形在禁用态下淡得像"只画了一半"。
        // 底部两个按钮只画图标：窗口本来就小，两个词组的文字比按钮本身还占地方。
        // 语义改由 tooltip + 无障碍标签承担（删组还会先确认，不怕误点）。
        addGroupButton = NSButton(title: "", target: self, action: #selector(addGroupTapped))
        addGroupButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建组")
        addGroupButton.imagePosition = .imageOnly
        addGroupButton.bezelStyle = .rounded
        addGroupButton.toolTip = "新建一个组"
        addGroupButton.setAccessibilityLabel("新建组")
        addGroupButton.translatesAutoresizingMaskIntoConstraints = false

        removeGroupButton = NSButton(title: "", target: self, action: #selector(removeGroupTapped))
        removeGroupButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除选中组")
        removeGroupButton.imagePosition = .imageOnly
        removeGroupButton.bezelStyle = .rounded
        removeGroupButton.setAccessibilityLabel("删除选中的组")
        removeGroupButton.translatesAutoresizingMaskIntoConstraints = false

        // 空状态提示：一个组都没有时，空表格会让人以为界面坏了。
        emptyLabel = NSTextField(labelWithString: "还没有组。点右下角的 + 开始；\n也可以跑 `Chord --seed-config` 生成一份演示配置。")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        permissionBanner = PermissionBannerView()
        permissionBanner.onAuthorize = { [weak self] in self?.onAuthorize?() }

        // 不做配置文件路径那行、也不做状态提示行：
        // 界面本身就能说明问题（删掉的 app 会消失、占用冲突显示在录制按钮上）。
        // 唯一的例外是权限——它不满足时什么都不会发生，界面自己说明不了。
        for view in [permissionBanner, scroll, emptyLabel, addGroupButton, removeGroupButton] as [NSView] {
            content.addSubview(view)
        }

        scrollTopToContent = scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12)
        scrollTopToBanner = scroll.topAnchor.constraint(equalTo: permissionBanner.bottomAnchor, constant: 10)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            // 空状态文字浮在表格上方居中
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -16),

            // 按钮行就是最后一行，靠**右下角**：− 在左、+ 在最右（图标按钮）
            addGroupButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            addGroupButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            addGroupButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            removeGroupButton.centerYAnchor.constraint(equalTo: addGroupButton.centerYAnchor),
            removeGroupButton.trailingAnchor.constraint(equalTo: addGroupButton.leadingAnchor, constant: -8),
            // 两个按钮等宽：系统 bezel 的宽度会随字形差几个点，`+`/`−` 看着就不像一对
            removeGroupButton.widthAnchor.constraint(equalTo: addGroupButton.widthAnchor),
        ])

        // 提示条的约束单独建：授权后它要**整组停用**，光 isHidden 不够 ——
        // AppKit 里隐藏的普通子视图照样参与布局，它那条「标题 + 去授权按钮」的宽度要求
        // 会把窗口撑宽 74pt（实测 359 → 433，而且这个尺寸还会被 autosave 记下来，
        // 看起来就像"APP 列右边怎么又空了一大块"）。
        permissionBannerConstraints = [
            permissionBanner.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            permissionBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            permissionBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ]
        NSLayoutConstraint.activate(permissionBannerConstraints)

        window.contentView = content
        reload()
    }

    func reload() {
        tableView.reloadData()
        refreshWidths()

        // 不自动选中任何行（用户明确不要）：没选中时删除按钮就是禁用态。
        // 禁用态用 SF Symbol 渲染，所以看起来是"正常的不可用按钮"，
        // 而不是最初那种"只画了一半"的错觉。
        let hasSelection = store.groups.indices.contains(tableView.selectedRow)
        removeGroupButton?.isEnabled = hasSelection
        removeGroupButton?.toolTip = hasSelection ? "删除选中的组（会先确认）" : "先在列表里选中一个组"
        emptyLabel?.isHidden = !store.groups.isEmpty
        refreshPermissionBanner()

        // 配置读不出来是数据完整性事件，值得用弹窗说一次——它没有别的地方可显示。
        if let backup = store.loadFailureBackupURL, !didReportLoadFailure {
            didReportLoadFailure = true
            let backupName = backup.lastPathComponent
            DispatchQueue.main.async { [weak self] in
                let alert = NSAlert()
                alert.messageText = "配置文件读不出来"
                alert.informativeText = """
                    原文件已备份为 \(backupName)，现在从空白配置开始（没有覆盖你的原文件）。

                    修好之后把它改名回 groups.json 即可恢复。
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.runModal()
                self?.tableView.reloadData()
            }
        }
    }

    /// 配置一变就把两列的宽度重算一遍：快捷键列跟着"最宽的那个快捷键"收放，
    /// 窗口的最小宽度跟着走。
    ///
    /// 列变宽时必须**把窗口也撑宽**（而不是让 APP 列让位）：APP 列窄下去图标会被挤扁，
    /// 那比"窗口悄悄长了一点"糟得多。列变窄时不动窗口——用户可能自己拖过尺寸。
    private func refreshWidths() {
        guard let window, let shortcutColumn = tableView.tableColumns.first else { return }
        let columnWidth = Self.shortcutColumnWidth(for: store.groups)
        shortcutColumn.width = columnWidth
        tableView.tableColumns.last?.width = Self.appsColumnWidth(for: store.groups)

        let needed = Self.defaultWidth(apps: store.groups, columnWidth: columnWidth)
        window.minSize = NSSize(width: needed, height: 240)
        if window.frame.width < needed {
            window.setContentSize(NSSize(width: needed, height: window.frame.height))
        }
    }

    /// 按 tap 是否可用显示/隐藏权限提示条。AppDelegate 在授权状态变化时调用。
    func refreshPermissionBanner() {
        guard let permissionBanner else { return }
        let needsPermission = !(isHotkeyTapAvailable?() ?? false)
        permissionBanner.isHidden = !needsPermission
        // 约束跟着开关（理由见 buildUI 末尾）
        permissionBannerConstraints.forEach { $0.isActive = needsPermission }
        scrollTopToBanner.isActive = needsPermission
        scrollTopToContent.isActive = !needsPermission
    }

    /// 诊断用：快捷键列现在有多宽（自适应逻辑要能被机械核对，见 --record-test）。
    var shortcutColumnWidth: CGFloat { tableView.tableColumns.first?.width ?? 0 }

    /// 诊断用：APP 列现在有多宽（同上）。
    var appsColumnWidth: CGFloat { tableView.tableColumns.last?.width ?? 0 }

    /// 诊断用：表格当前选中的是哪一行。
    var selectedRowDescription: String {        let row = tableView?.selectedRow ?? -1
        guard store.groups.indices.contains(row) else { return "无（表格没有选中行）" }
        return "第 \(row + 1) 行（\(store.groups[row].shortcutLabel)）"
    }

    /// 诊断用：渲染前先选中某一行。
    ///
    /// 表格故意不自动选中任何行（没选中时「删除选中组」是禁用态），所以
    /// `--render-window` 渲出来的图里从来没见过"选中行长什么样"——
    /// 要改选中行的颜色，就得先能把它渲出来看。
    func selectRowForDiagnostics(_ row: Int) {
        guard store.groups.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: 布局诊断

    /// 诊断用：**最长那一行**的内容右端，距列右端还剩多少空隙。
    ///
    /// 用来回答"窗口还能窄多少"——对着截图目测算不准，量出来才是数。
    func widestRowTrailingGap() -> String {
        guard !store.groups.isEmpty else { return "（没有组）" }
        let row = store.groups.enumerated().max { $0.element.apps.count < $1.element.apps.count }?.offset ?? 0
        guard let cell = tableView.view(atColumn: 1, row: row, makeIfNecessary: true) as? AppsCellView else {
            return "（拿不到第 \(row + 1) 行的 APP 单元格）"
        }
        cell.layoutSubtreeIfNeeded()

        guard let plus = cell.subviews.compactMap({ $0 as? NSButton }).first else {
            return "（第 \(row + 1) 行的单元格里找不到 ⊕）"
        }
        let plusFrame = plus.convert(plus.bounds, to: cell)
        let gap = cell.bounds.maxX - plusFrame.maxX
        let strip = cell.strip.convert(cell.strip.bounds, to: cell)
        return "第 \(row + 1) 行（\(store.groups[row].apps.count) 个 app）："
            + " 图标条 w=\(Int(strip.width)) ⊕ 右端 x=\(Int(plusFrame.maxX))"
            + " 列宽=\(Int(cell.bounds.width)) → 右端空隙 \(Int(gap))pt"
    }

    /// 供 `--ui-metrics` 用：把关键控件的实际 frame 报出来。
    /// "按钮显示不全"这类问题要么是被裁掉、要么是状态渲染，量一下就能分开。
    func layoutReport() -> [String] {
        guard let content = window?.contentView else { return ["（没有 contentView）"] }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds

        func describe(_ name: String, _ view: NSView?) -> String {
            guard let view else { return "  \(name): 不存在" }
            let frame = view.convert(view.bounds, to: content)
            let inside = bounds.contains(frame)
            return "  \(name): x=\(Int(frame.minX)) y=\(Int(frame.minY)) "
                + "w=\(Int(frame.width)) h=\(Int(frame.height))"
                + (inside ? "" : "   ← 超出 contentView（会被裁）")
                + (view is NSButton ? ((view as! NSButton).isEnabled ? "  [启用]" : "  [禁用：没选中行]") : "")
        }

        return [
            "  contentView: \(Int(bounds.width)) x \(Int(bounds.height))",
            describe("权限提示条", permissionBanner?.isHidden == false ? permissionBanner : nil),
            describe("表格 scroll", scrollView),
            describe("+ 按钮（右下角）", addGroupButton),
            describe("− 按钮", removeGroupButton),
            describe("空状态文字", emptyLabel),
        ]
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { store.groups.count }

    /// 选中行的底色自己画（见 `LightSelectionRowView`）。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LightSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.groups.indices.contains(row), let tableColumn else { return nil }
        let group = store.groups[row]

        switch tableColumn.identifier.rawValue {
        case "shortcut":
            let identifier = NSUserInterfaceItemIdentifier("ShortcutCellView")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? ShortcutCellView)
                ?? ShortcutCellView()
            view.identifier = identifier
            view.configure(
                group: group,
                isRecording: recordingRow == row,
                onRecord: { [weak self] in self?.beginRecording(row: row) },
                onClearShortcut: { [weak self] in self?.store.clearShortcut(groupAt: row) }
            )
            return view

        case "apps":
            let identifier = NSUserInterfaceItemIdentifier("AppsCellView")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? AppsCellView)
                ?? AppsCellView()
            view.identifier = identifier
            view.configure(
                group: group,
                onAddApp: { [weak self] in self?.presentAppPicker(forRow: row) },
                onRemoveApp: { [weak self] index in self?.removeApp(groupAt: row, appAt: index) }
            )

            // 拖动落下：源组 == 目标组就是排序，否则是换组。
            view.strip.onDrop = { [weak self] sourceGroupID, sourceIndex, insertIndex in
                guard let self,
                      let targetIndex = self.store.groups.firstIndex(where: { $0.id == group.id }) else { return }
                guard let sourceGroupIndex = self.store.groups.firstIndex(where: { $0.id == sourceGroupID }) else { return }
                if sourceGroupIndex == targetIndex {
                    self.store.moveAppWithinGroup(targetIndex, from: sourceIndex, to: insertIndex)
                } else {
                    // 跨组：插入下标在目标组里**直接可用**（目标条里没有被拖项，无 ±1 偏移），
                    // 所以落点就是插入线画的那个位置，而不是一律追加到末尾。
                    self.store.moveApp(fromGroup: sourceGroupIndex, appAt: sourceIndex,
                                       toGroup: targetIndex, at: insertIndex)
                }
            }
            return view

        default:
            return nil
        }
    }

    // MARK: 动作

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeGroupButton?.isEnabled = store.groups.indices.contains(tableView.selectedRow)
    }

    @objc private func addGroupTapped() {
        store.addGroup()
        let last = store.groups.count - 1
        tableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        tableView.scrollRowToVisible(last)
    }

    @objc private func removeGroupTapped() {
        let row = tableView.selectedRow
        guard store.groups.indices.contains(row) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "删除这个组？"
        alert.informativeText = "组里的 \(store.groups[row].apps.count) 个 app 绑定会一起删掉，app 本身不受影响。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        endRecording()
        store.removeGroup(at: row)
    }

    /// 移除组里的一个 app。绑定是廉价可重建的，所以不弹确认——
    /// 图标当场消失本身就是反馈，不需要再写一行字。
    private func removeApp(groupAt row: Int, appAt appIndex: Int) {
        store.removeApp(groupAt: row, appAt: appIndex)
    }

    private func presentAppPicker(forRow row: Int) {
        guard let window else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            var duplicates: [AppRef] = []
            for url in panel.urls {
                let name = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
                let app = AppRef(path: url.path, displayName: name)
                if !self.store.appendApp(app, groupAt: row) {
                    duplicates.append(app)      // 已在本组：加不进去，但要让人看见是哪一个
                }
            }
            self.reload()

            // 重复添加时图标数不会变，光看界面像"没反应"——把已有的那个闪一下。
            // 同一个 app 允许出现在别的组，那件事看别的行就知道，不用提示。
            if !duplicates.isEmpty,
               let cell = self.tableView.view(atColumn: 1, row: row, makeIfNecessary: false) as? AppsCellView {
                for app in duplicates { cell.flashApp(app) }
            }
        }
    }

    // MARK: 录制

    /// 供自测驱动（--record-test）。生产路径由录音按钮触发。
    func beginRecording(row: Int) {
        guard store.groups.indices.contains(row) else { return }

        // 录制和触发共用同一个 CGEventTap，没授权就录不了。
        // 不弹模态框：原因和出路都已经写在顶部提示条上，闪一下把视线引过去即可。
        guard isHotkeyTapAvailable?() ?? false else {
            NSSound.beep()
            refreshPermissionBanner()
            permissionBanner?.flash()
            return
        }

        recordingRow = row
        reload()
    }

    private func endRecording() {
        guard recordingRow != nil else { return }
        recordingRow = nil
        // 待定值也要清：否则取消录制后残留的 pendingShortcut 会在**下一次**录制
        // 按修饰键松手时被当成"这次录的"提交进去（Esc 取消那条路长期带着这个隐患）。
        pendingShortcut = nil
        lastRejected = nil
        reload()
    }

    /// 关窗 = 结束录制。**这条不是可选的**：录制态下 `consumeWhileRecording` 会把
    /// 每一个 keyDown/keyUp/修饰键变化都吞掉，且它的 tap 是 session 级、head 插入的
    /// —— 留下录制态等于整机键盘失灵（连打字都不行），而不是"只有快捷键不灵"。
    func windowWillClose(_ notification: Notification) {
        endRecording()
    }

    /// 切到别的 app 也一样：录制手势已经被打断了，没有理由继续吃键。
    @objc private func appDidResignActive() {
        endRecording()
    }

    /// 录制失败的原因显示在**录制按钮自己身上**，而不是另起一行：
    /// 用户正在盯着那个按钮按键，答案就该出现在那里。
    private func recorderCell(at row: Int) -> ShortcutCellView? {
        tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ShortcutCellView
    }

    /// AppDelegate 在全局 tap 回调里调用。返回 true = 事件被录制流程吃掉。
    func consumeWhileRecording(_ event: HotkeyTap.KeyEvent) -> Bool {
        guard let row = recordingRow else { return false }
        guard store.groups.indices.contains(row) else {   // 组在录制期间被删掉了
            endRecording()
            return true
        }

        // 修饰键状态变化：和弦破了就提交待定值。
        // **这是"按错了能改"的关键** —— 按住修饰键期间不落盘，所以可以再按一个键替换。
        if event.type == .flagsChanged {
            if let pending = pendingShortcut, !event.nsFlags.isSuperset(of: pending.modifiers) {
                commitPending(recordingRow: row)
            }
            return true                                  // 录制期间连修饰键事件也吞掉
        }

        guard event.type == .keyDown, !event.isRepeat else { return true }

        if event.keycode == 53 {                         // Esc
            endRecording()
            return true
        }

        let flags = GroupConfig.normalized(event.nsFlags)
        guard !flags.intersection([.command, .option, .control]).isEmpty else {
            recorderCell(at: row)?.recorder.showTransientMessage("需要 ⌘/⌥/⌃")
            return true
        }

        let keyCode = UInt16(truncatingIfNeeded: event.keycode)

        if let conflict = store.groups.enumerated().first(where: {
            $0.offset != row && $0.element.keyCode == keyCode && $0.element.modifiers == flags.rawValue
        }) {
            // 同一个组合连按两次 = 交换两组快捷键。
            // 不用弹窗：模态框会打断"按住修饰键"的手势，而那一刻手还按着键。
            if let last = lastRejected, last.keyCode == keyCode, last.modifiers == flags {
                swapShortcuts(recordingRow: row, otherRow: conflict.offset)
                endRecording()
                return true
            }
            lastRejected = (keyCode, flags)
            recorderCell(at: row)?.recorder.showTransientMessage(
                "\(KeyLabel.describe(keyCode: keyCode, modifiers: flags)) 第 \(conflict.offset + 1) 组占用")
            return true
        }

        // 没撞车 → 记为**待定**，先不落盘
        lastRejected = nil
        pendingShortcut = (keyCode, flags)
        recorderCell(at: row)?.recorder.showPending(
            KeyLabel.describe(keyCode: keyCode, modifiers: flags))
        return true
    }

    /// 提交待定组合。**先清录制状态再落盘**：setShortcut 会触发按快捷键重排，
    /// 之后 recordingRow 可能指向别的组。
    private func commitPending(recordingRow row: Int) {
        defer { reload() }
        guard let pending = pendingShortcut else { endRecording(); return }
        pendingShortcut = nil
        lastRejected = nil
        self.recordingRow = nil
        guard store.groups.indices.contains(row) else { return }
        store.setShortcut(pending.keyCode, modifiers: pending.modifiers, groupAt: row)
    }

    /// 交换两个组的快捷键。把 ⌘4 按错成 ⌘2、而 ⌘2 已被别的组占用时用得上。
    /// 两次 setShortcut 之间会重排，所以用 id 定位而不是下标。
    private func swapShortcuts(recordingRow row: Int, otherRow: Int) {
        guard store.groups.indices.contains(row), store.groups.indices.contains(otherRow) else { return }
        let mineID = store.groups[row].id
        let theirsID = store.groups[otherRow].id
        let mine = (store.groups[row].keyCode, store.groups[row].modifierFlags)
        let theirs = (store.groups[otherRow].keyCode, store.groups[otherRow].modifierFlags)

        store.setShortcut(theirs.0, modifiers: theirs.1, groupID: mineID)
        store.setShortcut(mine.0, modifiers: mine.1, groupID: theirsID)
        AppStatus.log("交换快捷键：第 \(row + 1) 组 ↔ 第 \(otherRow + 1) 组")
    }
}
