import Cocoa

/// 把一个视图渲染成 PNG（带缩放）。诊断用。
func renderViewToPNG(_ view: NSView, scale: CGFloat, path: String) -> Bool {
    let size = view.bounds.size
    guard size.width > 0, size.height > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }

    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    view.layer?.render(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
}

/// 用 AppKit 自己的绘制路径把视图渲成 PNG（按窗口的 backing scale）。
/// 控件（按钮、表头）只有走这条路才画得出来。
func renderViewByCachingDisplay(_ view: NSView, path: String) -> Bool {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    // 离屏窗口不画窗口背景：先铺一层，否则透明处是白的、深色模式下文字会"消失"。
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
}

/// `--render-window <png>`：把配置窗渲成图片。
///
/// 用途是回答"这一版界面到底长什么样"——尤其是那些我基于**误读**改过的地方
/// （比如表格现在是否始终有一行高亮）。这类问题文字描述容易来回扯，
/// 渲出来看一眼最快。
func runRenderWindowAndExit() -> Never {
    let arguments = CommandLine.arguments
    let path = arguments.firstIndex(of: "--render-window").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    } ?? NSTemporaryDirectory() + "chord-window.png"

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    // 先清掉**本进程域里**可能留下的陈旧窗口尺寸：裸二进制的 UserDefaults 落在 `Chord` 域
    // （和 .app 的 com.hiauhong.chord 不是一个），上一次量尺寸/渲染写进去的值会让窗口
    // 一创建就套上那个尺寸 —— 量到的就不是默认几何了（这个坑咬过两次）。
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(SettingsWindowController.frameAutosaveName)")

    let controller = SettingsWindowController()
    guard let window = controller.window, let content = window.contentView else {
        print("无法创建配置窗。")
        exit(1)
    }

    // 先摘掉 autosave：渲染会摆弄窗口尺寸，不摘的话退出时 AppKit 会把它写回去，
    // 于是"渲一张图看看"就改掉了用户自己的窗口大小。
    window.setFrameAutosaveName("")

    // 渲染的是**授权后**的样子：CLI 进程本身没有辅助功能权限，不显式声明就会渲染成
    // 带那条橙色提示条的版本 —— 而用户看到的是没有提示条的版本，宽度也不一样（提示条比
    // 窗口的最小宽度还宽，会把内容撑宽十几点）。
    controller.isHotkeyTapAvailable = { true }
    controller.reload()

    // **按默认尺寸渲**：用户此刻的窗口大小可能被上一次量尺寸污染过，
    // 拿它渲出来的图不能代表"默认长什么样"（踩过：433 宽，还写回了 autosave）。
    window.setContentSize(NSSize(width: SettingsWindowController.defaultWidth(
        apps: ConfigStore.shared.groups, columnWidth: SettingsWindowController.shortcutColumnWidth(
            for: ConfigStore.shared.groups)),
                                 height: 500))

    // `--select N`：先选中第 N 行（1 起）再渲染。表格默认不选中任何行，
    // 不选的话"选中行的底色"根本不会出现在图里——改那个颜色时就无从核对。
    if let index = arguments.firstIndex(of: "--select"), arguments.indices.contains(index + 1),
       let row = Int(arguments[index + 1]) {
        controller.selectRowForDiagnostics(row - 1)
    }

    // 离屏窗口的外观要显式跟随系统，否则控件和表格会各用一套（浅色按钮配白字）。
    window.appearance = application.effectiveAppearance
    content.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    // 配置窗用 cacheDisplay 而不是 layer.render：后者不画非 layer-backed 的
    // AppKit 控件（底部按钮渲出来是空白框），cacheDisplay 走的是真实的 draw 路径。
    guard renderViewByCachingDisplay(content, path: path) else {
        print("渲染失败。")
        exit(1)
    }

    print("已渲染：\(path)")
    print("  尺寸 \(Int(content.bounds.width))x\(Int(content.bounds.height))，2 倍输出")
    print("  表格选中行：\(controller.selectedRowDescription)")
    print("  组数：\(ConfigStore.shared.groups.count)")
    exit(0)
}
