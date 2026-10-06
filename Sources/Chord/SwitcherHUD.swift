import Cocoa

/// 切换浮层。
///
/// 三个必须做对的点：
///   1. **非激活** NSPanel —— 否则浮层一出现就把焦点从前台 app 抢走，
///      松手提交时前台 app 已经变了，切换就乱了。
///   2. 窗口层级要够高 + `canJoinAllSpaces` / `fullScreenAuxiliary`，
///      否则在别的 Space 的全屏 app 里根本看不见浮层（会以为快捷键没反应）。
///   3. 鼠标事件穿透（`ignoresMouseEvents`）——现阶段浮层只做展示，不接点击。
final class SwitcherHUD {

    private var panel: NSPanel?
    private let effect = NSVisualEffectView()
    private let root = NSStackView()
    private let header = NSStackView()
    private let shortcutCaps = KeycapsView()
    private let appsRow = NSStackView()
    private let divider = NSBox()
    private let windowsRow = NSStackView()
    private let progressLabel = NSTextField(labelWithString: "")

    private let iconSize: CGFloat = 48
    /// app 格子统一宽度：名字长短不一时，格子也要一样大，否则一排看起来参差。
    private let tileWidth: CGFloat = 96
    /// 窗口条目统一最小宽度：同一列的高亮条才一样长。
    private let windowRowWidth: CGFloat = 200

    // MARK: 显示

    func show(_ state: GroupSwitcher.State) {
        buildPanelIfNeeded()
        guard let panel, refreshContent(state) != nil else { return }

        let padded = preferredContentSize()
        panel.setContentSize(padded)
        position(panel, size: padded)
        panel.orderFrontRegardless()
    }

    /// 内容期望尺寸 = 根 stack 的合适尺寸 + 内边距。
    ///
    /// 注意**必须量根 stack，不能量 contentView**：内容视图是个普通 NSView，
    /// 没有固有尺寸，`fittingSize` 会是 0 —— 于是浮层被算成 0 尺寸。
    /// （重构时踩过，是 --render-hud 第一次跑就报"渲染失败"暴露出来的。）
    func preferredContentSize() -> NSSize {
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        return NSSize(width: size.width, height: size.height)
    }

    /// 只刷新内容、返回内容视图，**不显示面板**。
    /// `show` 与渲染诊断（`--render-hud`）共用它——诊断不该为了看一眼就把浮层闪出来。
    @discardableResult
    func refreshContent(_ state: GroupSwitcher.State) -> NSView? {
        buildPanelIfNeeded()
        guard let panel else { return nil }

        shortcutCaps.tokens = Keycaps.tokens(of: state.shortcut)
        rebuildAppsRow(state)
        rebuildWindowsRow(state)
        divider.isHidden = windowsRow.isHidden
        progressLabel.stringValue = "\(state.layerIndex + 1) / \(state.layerCount)"
        return panel.contentView
    }

    /// 诊断用：窗口行**每列各有多少个条目**（列 = 一块有窗口的屏幕）。
    /// 让"分列布局"这个纯视觉的东西也能被断言，而不只是看一眼。
    /// （跳过两端的居中空位，它们不是列。）
    var windowColumnCounts: [Int] {
        windowsRow.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.count }
    }

    /// 诊断用：app 行里各格子的 frame（换算到浮层内容视图的坐标系）。
    /// 单 app 组里浮层宽度由顶栏撑着，格子还居不居中只能量——"看着偏了"没法断言。
    var appTileFrames: [NSRect] {
        guard let content = panel?.contentView else { return [] }
        return appsRow.arrangedSubviews
            .filter { $0.identifier?.rawValue != Self.centeringSpacerIdentifier }
            .map { $0.convert($0.bounds, to: content) }
    }

    /// 诊断用：app 行本身在内容视图里的 frame（判断"格子左偏"是行的锅还是格子的锅）。
    var appRowFrame: NSRect? {
        guard let content = panel?.contentView else { return nil }
        return appsRow.convert(appsRow.bounds, to: content)
    }

    private static let centeringSpacerIdentifier = "chord-centering-spacer"

    /// 往一行两端各塞一个**可伸缩的空位**：行被拉得比内容宽时，内容留在中间而不是贴左端。
    ///
    /// 为什么需要：浮层宽度常常是顶栏（键帽 + 进度）撑到最小宽度 180 的，而行宽被
    /// 「≤ root−32」那条约束钉在了内边距上（实测行宽 148、里面唯一的格子 96 贴左，
    /// 偏 26pt —— `--render-hud` 里量出来的）。两端空位等宽，于是内容居中。
    /// app/窗口多到放不下时，空位被压到 0，不影响原来的排布。
    private func addCenteringSpacers(to row: NSStackView) {
        let leading = NSView()
        let trailing = NSView()
        for spacer in [leading, trailing] {
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.identifier = NSUserInterfaceItemIdentifier(Self.centeringSpacerIdentifier)
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            row.addArrangedSubview(spacer)
        }
        leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
        // 空位两侧不占间距：stack 的 spacing 对每个相邻对都生效，不清掉浮层会白宽 2×spacing。
        row.setCustomSpacing(0, after: leading)
    }

    /// 内容装完之后再清一次：末端空位前面那个间距要等最后一个条目加完才知道是谁。
    private func trimCenteringSpacing(in row: NSStackView) {
        let views = row.arrangedSubviews
        guard views.count >= 2 else { return }
        row.setCustomSpacing(0, after: views[views.count - 2])
    }

    /// 供渲染诊断用：刷新内容、定好尺寸，并**强制完成一次显示**。
    ///
    /// 为什么需要"强制显示"：内容视图不在任何已显示的窗口里时，图层的树还没建，
    /// 直接 render 会得到一张全白图（实测）。layout + displayIfNeeded + flush
    /// 才能把图层树落实。
    func prepareForDiagnostics(_ state: GroupSwitcher.State) -> NSView? {
        guard let content = refreshContent(state) else { return nil }
        content.wantsLayer = true
        content.frame = NSRect(origin: .zero, size: preferredContentSize())
        content.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
        CATransaction.begin()
        CATransaction.flush()
        CATransaction.commit()
        return content
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: 面板

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 90),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered,
                            defer: false)
        panel.level = .screenSaver                       // 盖得住全屏 app
        panel.collectionBehavior = [.canJoinAllSpaces,   // 每个 Space 都出现
                                   .fullScreenAuxiliary, // 全屏 app 之上
                                   .transient,
                                   .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true                  // 只展示，不接点击
        panel.hidesOnDeactivate = false                  // 我们不是激活的 app，别自动收
        panel.animationBehavior = .none

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        // 一圈极细的亮边：深色背景上浮层边缘才利落，不会糊进底下的窗口里
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false

        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        // 顶栏：左边是这一组的快捷键（键帽），右边是当前层的进度。
        // 按住修饰键时看一眼就知道"我在哪一组、第几个"。
        // 浮层是深色底：键帽底要比配置窗（浅色底）浓，否则只剩字形浮在那儿、看不出是键帽。
        shortcutCaps.style = Keycaps.Style(fontSize: 11, height: 18, spacing: 2,
                                           faceAlpha: 0.10, edgeAlpha: 0.22)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.setViews([shortcutCaps, spacer, progressLabel], in: .leading)

        appsRow.orientation = .horizontal
        appsRow.alignment = .top
        appsRow.spacing = 6
        // 两行都要**贴住自己的内容**，否则单 app 组的格子会贴左边：
        // 浮层宽度这时是被顶栏（键帽 + 进度）撑到最小宽度 180 的，行若跟着被拉宽，
        // 里面唯一那个格子就落在行的左端（实测偏 26pt，--render-hud 里量出来的）。
        // 750 < 下面「行宽 ≤ root−32」那条 required 约束，所以 app/窗口多到放不下时
        // 照样会被卡在浮层内边距里。
        let hugging = NSLayoutConstraint.Priority(750)
        appsRow.setContentHuggingPriority(hugging, for: .horizontal)

        divider.boxType = .separator

        // 窗口行是一列一块屏，所以列之间拉开距离、顶部对齐
        windowsRow.orientation = .horizontal
        windowsRow.alignment = .top
        windowsRow.spacing = 14
        windowsRow.setContentHuggingPriority(hugging, for: .horizontal)

        root.addArrangedSubview(header)
        root.addArrangedSubview(appsRow)
        root.addArrangedSubview(divider)
        root.addArrangedSubview(windowsRow)
        effect.addSubview(root)

        let content = NSView()
        content.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            effect.topAnchor.constraint(equalTo: content.topAnchor),
            effect.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            root.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            // 顶栏与分隔线横跨整个内容宽度（减去左右内边距）
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            divider.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            // 内容行不许越过内边距。NSStackView 自己的边距约束优先级不够高，
            // 窗口行一宽就会贴到浮层边上（--render-hud 渲出来才发现）。
            appsRow.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
            windowsRow.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
            // 只有一个 app 时内容很窄，顶栏的键帽和进度会挤在一起
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        panel.contentView = content

        self.panel = panel
    }

    /// 放在鼠标所在那块屏幕的下方居中。
    /// 选鼠标所在屏而不是"有菜单栏那块"或"焦点窗那块"：眼睛在哪里，浮层就在哪里。
    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + 110))
    }

    // MARK: 两行内容

    private func rebuildAppsRow(_ state: GroupSwitcher.State) {
        clear(appsRow)
        addCenteringSpacers(to: appsRow)
        for (index, app) in state.apps.enumerated() {
            // 在窗口层时，app 行的高亮表示「正在哪个 app 里」而不是选中项，
            // 所以它始终跟着 appIndex——下层选中哪个窗口由窗口行自己标。
            let isCurrent = index == state.appIndex
            // 在 app 层它是"选中"，在窗口层它只是"你在哪个 app 里"
            let emphasis: Emphasis = isCurrent ? (state.layer == .apps ? .selected : .context) : .none
            // 空位要停在两端，所以插在最后一个空位之前
            appsRow.insertArrangedSubview(appTile(icon: NSWorkspace.shared.icon(forFile: app.path),
                                                 title: app.displayName,
                                                 index: index,
                                                 emphasis: emphasis),
                                         at: appsRow.arrangedSubviews.count - 1)
        }
        trimCenteringSpacing(in: appsRow)
    }

    /// 窗口行**按屏幕分列**：一列 = 一块有窗口的屏幕，列内按上→下排。
    ///
    /// 这样布局本身就带着"在哪块屏、靠上还是靠下"的信息，
    /// 多屏时不用读文字就知道该往哪个方向找。
    private func rebuildWindowsRow(_ state: GroupSwitcher.State) {
        clear(windowsRow)
        guard state.layer == .windows else {
            windowsRow.isHidden = true
            return
        }
        windowsRow.isHidden = false
        addCenteringSpacers(to: windowsRow)

        // screenIndex == nil（读不到位置）归到最后一列
        let grouped = Dictionary(grouping: state.windows.enumerated()) {
            $0.element.screenIndex ?? Int.max
        }
        for screen in grouped.keys.sorted() {
            let entries = (grouped[screen] ?? []).sorted { $0.offset < $1.offset }

            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .width          // 条目撑满列宽：高亮条一样长
            column.spacing = 2
            for (index, window) in entries {
                column.addArrangedSubview(windowRow(title: window.title,
                                                    isMinimized: window.isMinimized,
                                                    isOnOtherSpace: window.isOnOtherSpace,
                                                    isPlaceholder: window.isPlaceholder,
                                                    index: index,
                                                    emphasis: index == state.windowIndex ? .selected : .none))
            }
            // 同 app 行：列插在最后一个居中空位之前
            windowsRow.insertArrangedSubview(column, at: windowsRow.arrangedSubviews.count - 1)
        }
        trimCenteringSpacing(in: windowsRow)
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// 条目的强调程度。
    ///
    /// 分三档是为了让**强调色只表示"当前选中"**：在窗口层时 app 行只是上下文
    /// （你在哪个 app 里），如果它也涂强调色，屏幕上就有两处"选中"，
    /// 反而看不出会切到哪一个（渲染出来才发现）。
    private enum Emphasis {
        case none        // 普通
        case context     // 上下文（灰底）
        case selected    // 当前选中（强调色）
    }

    /// 圆角底色：选中 = 强调色，上下文 = 浅灰，普通 = 透明。
    private func background(_ emphasis: Emphasis, radius: CGFloat) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = radius
        container.layer?.cornerCurve = .continuous
        switch emphasis {
        case .selected:
            container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        case .context:
            container.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        case .none:
            container.layer?.backgroundColor = NSColor.clear.cgColor
        }
        return container
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// app 格子：大图标在上、名字在下（Cmd+Tab 的读法），左上角是序号。
    /// 序号让「按 N 次」和「第 N 个」能对上。
    private func appTile(icon: NSImage, title: String, index: Int, emphasis: Emphasis) -> NSView {
        let tile = background(emphasis, radius: 12)
        let onAccent = emphasis == .selected

        let imageView = NSImageView()
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let name = label(title, size: 11, weight: onAccent ? .semibold : .regular,
                         color: onAccent ? .white : .labelColor)
        name.alignment = .center

        let number = label("\(index + 1)", size: 9, weight: .bold,
                           color: onAccent ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor)
        number.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)

        for view in [imageView, name, number] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: tileWidth),
            imageView.topAnchor.constraint(equalTo: tile.topAnchor, constant: 10),
            imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),
            name.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -9),
            number.topAnchor.constraint(equalTo: tile.topAnchor, constant: 6),
            number.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 8),
        ])
        return tile
    }

    /// 窗口条目：序号 + 窗口符号 + 标题。换符号的两种情况，都是"选它屏幕会动一下"：
    /// 最小化的窗口（要从 Dock 里拉出来）、在别的桌面上的窗口（那块屏会切过去）。
    private func windowRow(title: String, isMinimized: Bool, isOnOtherSpace: Bool,
                           isPlaceholder: Bool, index: Int, emphasis: Emphasis) -> NSView {
        let row = background(emphasis, radius: 7)
        let onAccent = emphasis == .selected

        let number = label("\(index + 1)", size: 10, weight: .semibold,
                           color: onAccent ? .white : .tertiaryLabelColor)
        number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

        // 三种"屏幕会动一下"的情况各给一个符号：占位行（切过去才会列出来）、
        // 别的桌面上的窗口（提它会切过去）、最小化（要从 Dock 里拉出来）。
        let symbolInfo: (name: String, description: String) = isPlaceholder
            ? ("arrow.right.circle", "切到另一个桌面")
            : (isMinimized ? ("minus.rectangle", "已最小化")
                           : (isOnOtherSpace ? ("rectangle.on.rectangle", "在别的桌面")
                                             : ("macwindow", "窗口")))
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: symbolInfo.name, accessibilityDescription: symbolInfo.description)
        symbol.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        symbol.contentTintColor = onAccent ? .white : .secondaryLabelColor

        let name = label(title.isEmpty ? "（无标题）" : title, size: 12, weight: onAccent ? .medium : .regular,
                         color: onAccent ? .white
                                         : ((isMinimized || isPlaceholder) ? .secondaryLabelColor : .labelColor))

        let stack = NSStackView(views: [number, symbol, name])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: windowRowWidth),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -5),
        ])
        return row
    }
}
