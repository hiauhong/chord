import Cocoa

/// `--render-chip <输出路径>`：把**真实的整行**渲染成 PNG。
///
/// 为什么必须带父视图：角标只在鼠标悬停时出现，我悬停不了；
/// 而且它探出 chip 边界，**裁它的不是 chip 而是 chip 外面的那排图标条**。
/// 只渲染孤立的一个 chip 复现不出这个问题——上一版诊断就是这么漏掉的。
/// 所以这里渲染的是生产环境里真正用的 `AppsCellView`（图标条 + ⊕）。
func runRenderChipAndExit() -> Never {
    let arguments = CommandLine.arguments
    let index = arguments.firstIndex(of: "--render-chip")
    let outputPath = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        ?? NSTemporaryDirectory() + "chord-cell.png"

    // 用真实存在的 app 才看得出效果。
    let candidates = ["/Applications/Google Chrome.app",
                      "/Applications/Safari.app",
                      "/System/Applications/Notes.app",
                      "/System/Applications/Calculator.app"]
    let apps = candidates.filter { FileManager.default.fileExists(atPath: $0) }.prefix(3).map { path in
        AppRef(path: path,
               displayName: FileManager.default.displayName(atPath: path)
                  .replacingOccurrences(of: ".app", with: ""))
    }
    guard !apps.isEmpty else {
        print("找不到任何可用的 app 用来渲染。")
        exit(1)
    }

    let group = GroupConfig(keyCode: 21, modifiers: [.command], apps: Array(apps))
    let cellSize = NSSize(width: 340, height: 60)   // 与配置窗的 rowHeight 一致
    let scale: CGFloat = 3
    let padding: CGFloat = 16
    let canvas = NSSize(width: cellSize.width + padding * 2, height: cellSize.height + padding * 2)

    let container = NSView(frame: NSRect(origin: .zero, size: canvas))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    let cell = AppsCellView()
    cell.frame = NSRect(x: padding, y: padding, width: cellSize.width, height: cellSize.height)
    cell.configure(group: group, onAddApp: {}, onRemoveApp: { _ in })
    container.addSubview(cell)

    // 模拟悬停要在**布局与提交之前**做：否则图层树里还是"角标隐藏"的旧状态，
    // 渲染出来会缺一块（这个诊断自己先踩过一次）。
    let chips = cell.strip.arrangedSubviews.compactMap { $0 as? AppChipView }
    chips.first?.showRemoveBadgeForDiagnostics()
    // 加 --indicator 时把插入指示线也画出来（拖动时才会出现，平时看不到）。
    if arguments.contains("--indicator") {
        cell.strip.showInsertionIndicatorForDiagnostics(at: 2)
    }

    let window = NSWindow(contentRect: container.frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.begin()
    CATransaction.flush()
    CATransaction.commit()

    guard renderViewToPNG(container, scale: scale, path: outputPath) else {
        print("渲染失败。")
        exit(1)
    }

    print("已渲染：\(outputPath)")
    print("  渲染的是真实的 AppsCellView（图标条 + ⊕），\(Int(cellSize.width))x\(Int(cellSize.height))，\(Int(scale)) 倍输出")
    print("  左侧第一个图标处于悬停态（角标已强制显示）")
    print("")

    guard let chip = chips.first else {
        print("  （没拿到 chip，无法量角标位置）")
        exit(0)
    }

    let stripFrame = cell.strip.convert(cell.strip.bounds, to: cell)
    print("  chip   frame（相对 cell）: \(rect(cell.convert(chip.bounds, from: chip)))")
    print("  图标条 frame（相对 cell）: \(rect(stripFrame))   高度 \(Int(stripFrame.height))")

    if let badge = chip.subviews.compactMap({ $0 as? NSButton }).first {
        let inChip = badge.convert(badge.bounds, to: chip)
        print("  角标 frame（相对 chip）: \(rect(inChip))"
              + (contained(inChip, in: chip.bounds) ? "  在 chip 内" : "  探出 chip（设计如此）"))

        // 只有 masksToBounds = true 的祖先才会裁。找最近的那个来判定——
        // 拿"图标条"当参照是错的：它 masksToBounds = false，裁不了任何东西。
        var clipper: NSView?
        var ancestor: NSView? = badge.superview
        while let current = ancestor {
            if current.layer?.masksToBounds == true { clipper = current; break }
            ancestor = current.superview
        }
        if let clipper {
            let inClipper = badge.convert(badge.bounds, to: clipper)
            print("  最近的裁剪祖先: \(String(describing: type(of: clipper)))"
                  + "  \(rect(inClipper))"
                  + (contained(inClipper, in: clipper.bounds) ? "  在内 ✅ 不会被裁" : "  超出 ❌ 会被裁"))
        } else {
            print("  最近的裁剪祖先: 无 —— 不会有任何裁剪 ✅")
        }

        // 谁在裁？逐级看 masksToBounds 与边界。**裁剪只由祖先的 masksToBounds 造成**，
        // 几何"在界内"并不等于没被裁——上一版就是靠这个把方向搞错的。
        print("")
        print("  从角标往上逐级检查（裁剪只可能来自 masksToBounds = true 的祖先）：")
        var node: NSView? = badge
        var depth = 0
        while let current = node {
            let masks = current.layer?.masksToBounds ?? false
            let frameInCell = current.convert(current.bounds, to: cell)
            let name = String(describing: type(of: current))
            print("    \(String(repeating: "  ", count: depth))\(name)"
                  + "  masksToBounds=\(masks ? "true  ← 会裁子视图" : "false")"
                  + "  bounds=\(rect(frameInCell))")
            node = current.superview
            depth += 1
        }
    }
    exit(0)
}

private func rect(_ frame: NSRect) -> String {
    "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
}

private func contained(_ frame: NSRect, in bounds: NSRect) -> Bool {
    frame.minX >= bounds.minX - 0.5 && frame.maxX <= bounds.maxX + 0.5
        && frame.minY >= bounds.minY - 0.5 && frame.maxY <= bounds.maxY + 0.5
}

/// `--render-recorder [png]`：把快捷键录制按钮的各个状态并排渲成一张图。
///
/// 录制中 / 待定 / 撞车提示都只在按键的那一瞬间出现，平时截不到——
/// 所以用真实的 `HotkeyRecorderButton` 逐个摆出来看。
func runRenderRecorderAndExit() -> Never {
    let arguments = CommandLine.arguments
    let path = arguments.firstIndex(of: "--render-recorder").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    } ?? NSTemporaryDirectory() + "chord-recorder.png"

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let states: [(String, (HotkeyRecorderButton) -> Void)] = [
        ("已绑定", { $0.show(shortcut: "⌘1") }),
        ("长组合", { $0.show(shortcut: "⌃⌥⌘F12") }),
        ("超长", { $0.show(shortcut: "⌃⌥⇧⌘F12") }),
        ("未绑定", { $0.show(shortcut: nil) }),
        ("录制中", { $0.show(shortcut: "⌘1"); $0.beginRecording() }),
        ("待定", { $0.show(shortcut: "⌘1"); $0.beginRecording(); $0.showPending("⌥⌘4") }),
        ("撞车", { $0.show(shortcut: "⌘1"); $0.beginRecording(); $0.showTransientMessage("⌘2 第 3 组占用") }),
    ]

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    for (name, apply) in states {
        let caption = NSTextField(labelWithString: name)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let button = HotkeyRecorderButton.make()
        apply(button)
        let row = NSStackView(views: [caption, button])
        row.spacing = 8
        stack.addArrangedSubview(row)
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 280),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = application.effectiveAppearance
    window.contentView = stack
    window.setContentSize(stack.fittingSize)
    stack.layoutSubtreeIfNeeded()

    guard renderViewByCachingDisplay(stack, path: path) else {
        print("渲染失败。")
        exit(1)
    }
    print("已渲染：\(path)（\(states.map(\.0).joined(separator: " / "))）")
    exit(0)
}
