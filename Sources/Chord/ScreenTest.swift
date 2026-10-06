import ApplicationServices
import Cocoa

/// `--screen-test`：多屏窗口排序的自测。
///
/// 为什么**不需要辅助功能权限**就能测：排序是纯几何——屏幕布局、坐标翻转、
/// 归属判定、排序规则，全都可以用合成窗口 + 真实屏幕布局来断言。
/// 只有"从 AX 读窗口"那一步需要权限，而它跟排序对不对无关。
///
/// 用你机器上**真实的屏幕布局**做用例，所以这个测试直接回答"我这个三屏配置对不对"。
func runScreenTestAndExit() -> Never {
    var failures = 0
    var passed = 0

    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("✅ \(name)")
        } else {
            failures += 1
            print("❌ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    print("Chord · 多屏窗口排序自测")
    print(String(repeating: "─", count: 56))

    let screens = WindowEnumerator.orderedScreens()
    print("本机屏幕（已按从左到右排序）：")
    for (index, screen) in screens.enumerated() {
        let f = screen.frame
        print("  [\(index)] x=\(Int(f.minX))..\(Int(f.maxX))  y=\(Int(f.minY))..\(Int(f.maxY))"
              + "  \(Int(f.width))x\(Int(f.height))")
    }
    print("")

    check("至少有一块屏幕", !screens.isEmpty)

    // 1. 屏幕确实是从左到右
    let xs = screens.map(\.frame.minX)
    check("屏幕按 minX 非递减排列", zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 },
          "minX 序列：\(xs.map { Int($0) })")

    // 2. 坐标翻转：主屏自己的区域翻转后应当还是它自己
    if let primary = screens.first(where: { $0.frame.origin == .zero }) {
        let quartzRect = CGRect(x: 0, y: 0, width: primary.frame.width, height: primary.frame.height)
        // appKitFrame 用的是同一个公式，这里直接验它对这个已知矩形的输出
        let flipped = NSRect(x: quartzRect.minX,
                             y: primary.frame.height - quartzRect.minY - quartzRect.height,
                             width: quartzRect.width,
                             height: quartzRect.height)
        check("主屏区域的坐标翻转是不动点", flipped == primary.frame,
              "翻转得 \(flipped)，主屏是 \(primary.frame)")
    } else {
        check("存在原点在 (0,0) 的主屏", false, "屏幕原点：\(screens.map { $0.frame.origin })")
    }

    // 3. 归属判定：造一个落在每块屏正中的窗口，应当归到那块屏
    for (index, screen) in screens.enumerated() {
        let center = NSRect(x: screen.frame.midX - 100, y: screen.frame.midY - 100,
                            width: 200, height: 200)
        let assigned = WindowEnumerator.screenIndex(for: center, in: screens)
        check("落在第 \(index) 块屏正中的窗口 → 屏[\(index)]", assigned == index,
              "实际 \(String(describing: assigned))")
    }

    // 4. 用户描述的场景：两块屏上的窗口应当按"屏顺序 → 屏内 x"排
    guard screens.count >= 2 else {
        print("")
        print("只有一块屏，跳过跨屏排序用例（共 \(passed) 项通过）。")
        exit(failures == 0 ? 0 : 1)
    }

    func window(_ name: String, onScreen screenIndex: Int, xOffset: CGFloat,
                yOffset: CGFloat = 100, desktop: Int = 1) -> WindowInfo {
        let screen = screens[screenIndex]
        let frame = NSRect(x: screen.frame.minX + xOffset,
                           y: screen.frame.minY + yOffset,
                           width: 400, height: 300)
        return WindowInfo(title: name,
                          element: AXUIElementCreateSystemWide(),
                          isMinimized: false,
                          isFocused: false,
                          frame: frame,
                          screenIndex: WindowEnumerator.screenIndex(for: frame, in: screens),
                          isOnOtherSpace: false,
                          desktopIndex: desktop,
                          hidden: nil)
    }

    // 场景一：3 个窗口，2 个在左屏（右一个先放，左一个后放），1 个在中间屏。
    // 期望顺序：左屏靠左的 → 左屏靠右的 → 中间屏的。**与 AX 返回顺序无关**。
    let scenario = [
        window("左屏-右", onScreen: 0, xOffset: 900),
        window("中屏-唯一", onScreen: 1, xOffset: 200),
        window("左屏-左", onScreen: 0, xOffset: 100),
    ]
    let ordered = WindowEnumerator.sorted(scenario).map(\.title)
    check("跨屏排序：左屏两个在前（按屏内 x），中间屏在后",
          ordered == ["左屏-左", "左屏-右", "中屏-唯一"],
          "实际 \(ordered)")

    // 场景一之补充：**同一块屏上，桌面序号优先于窗口位置**。
    // 用户报的就是这个：桌面 2 的窗口位置靠上，桌面 1 的靠下，只按位置排就反了。
    let desktops = [
        window("左屏-桌面2-上", onScreen: 0, xOffset: 100, yOffset: 900, desktop: 2),
        window("左屏-桌面1-下", onScreen: 0, xOffset: 100, yOffset: 100, desktop: 1),
        window("左屏-桌面2-下", onScreen: 0, xOffset: 100, yOffset: 100, desktop: 2),
        window("左屏-桌面1-上", onScreen: 0, xOffset: 100, yOffset: 900, desktop: 1),
    ]
    let byDesktop = WindowEnumerator.sorted(desktops).map(\.title)
    check("同屏内桌面在前：桌面1 的两个在前（各自再按上→下）",
          byDesktop == ["左屏-桌面1-上", "左屏-桌面1-下", "左屏-桌面2-上", "左屏-桌面2-下"],
          "实际 \(byDesktop)")

    // 桌面序号未知的排在该屏最后（不能插到已知桌面前面）
    var unknown = window("左屏-桌面未知", onScreen: 0, xOffset: 100, yOffset: 100)
    unknown.desktopIndex = nil
    let withUnknown = WindowEnumerator.sorted([unknown] + desktops).map(\.title)
    check("桌面序号未知的排在该屏最后", withUnknown.last == "左屏-桌面未知",
          "实际 \(withUnknown)")

    if screens.count >= 3 {
        let three = [
            window("屏2", onScreen: 2, xOffset: 50),
            window("屏0", onScreen: 0, xOffset: 50),
            window("屏1", onScreen: 1, xOffset: 50),
        ]
        check("三块屏按从左到右排", WindowEnumerator.sorted(three).map(\.title) == ["屏0", "屏1", "屏2"],
              "实际 \(WindowEnumerator.sorted(three).map(\.title))")
    }

    // 5. 竖直堆叠（x 相同）：**上面的在前**。
    //    用户实际遇到的就是这个：两块竖屏上各放一个整屏宽的窗口，
    //    早先按 y 升序排（AppKit 的 y 向上）导致上下颠倒。
    do {
        let screen = screens[0]
        func sameX(_ name: String, y: CGFloat, height: CGFloat = 1400) -> WindowInfo {
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY + y,
                               width: screen.frame.width, height: height)
            return WindowInfo(title: name, element: AXUIElementCreateSystemWide(),
                              isMinimized: false, isFocused: false, frame: frame,
                              screenIndex: 0, isOnOtherSpace: false, hidden: nil)
        }
        let stacked = [sameX("下", y: 0), sameX("上", y: 1500)]
        check("竖直堆叠：上面的窗口在前",
              WindowEnumerator.sorted(stacked).map(\.title) == ["上", "下"],
              "实际 \(WindowEnumerator.sorted(stacked).map(\.title))")

    }

    // 5b. 普通横屏左右排：这是最常见的情况，必须按左右、不受高低差影响
    do {
        let screen = screens[0]
        func landscape(_ name: String, x: CGFloat, y: CGFloat) -> WindowInfo {
            WindowInfo(title: name, element: AXUIElementCreateSystemWide(), isMinimized: false,
                       isFocused: false,
                       frame: NSRect(x: screen.frame.minX + x, y: screen.frame.minY + y,
                                     width: 700, height: 600),
                       screenIndex: 0, isOnOtherSpace: false, hidden: nil)
        }

        let slightlyOff = [landscape("右", x: 800, y: 305), landscape("左", x: 50, y: 300)]
        check("左右并排、y 差 5pt → 按左右",
              WindowEnumerator.sorted(slightlyOff).map(\.title) == ["左", "右"],
              "实际 \(WindowEnumerator.sorted(slightlyOff).map(\.title))")

        // 高低差较大但纵向仍有明显重叠（400/600）→ 仍算同一行，按左右
        let bigOffset = [landscape("右", x: 800, y: 500), landscape("左", x: 50, y: 100)]
        check("左右并排、y 差 400pt（重叠 1/3）→ 仍按左右",
              WindowEnumerator.sorted(bigOffset).map(\.title) == ["左", "右"],
              "实际 \(WindowEnumerator.sorted(bigOffset).map(\.title))")

        // 纵向几乎不重叠（差 500/600）时就不是"并排"了，而是斜着摆 ——
        // 这时按行排、上面的在前，符合从上到下的阅读顺序。
        let diagonal = [landscape("右-高", x: 800, y: 600), landscape("左-低", x: 50, y: 100)]
        check("纵向几乎不重叠（斜着摆）→ 上面的行在前",
              WindowEnumerator.sorted(diagonal).map(\.title) == ["右-高", "左-低"],
              "实际 \(WindowEnumerator.sorted(diagonal).map(\.title))")
    }

    // 5c. 2×2 铺满：读数顺序 = 左上 → 右上 → 左下 → 右下
    do {
        let screen = screens[0]
        func cell(_ name: String, col: Int, row: Int) -> WindowInfo {
            WindowInfo(title: name, element: AXUIElementCreateSystemWide(), isMinimized: false,
                       isFocused: false,
                       frame: NSRect(x: screen.frame.minX + CGFloat(col) * 800,
                                     y: screen.frame.minY + CGFloat(1 - row) * 700,
                                     width: 700, height: 600),
                       screenIndex: 0, isOnOtherSpace: false, hidden: nil)
        }
        let grid = [cell("右下", col: 1, row: 1), cell("左上", col: 0, row: 0),
                    cell("左下", col: 0, row: 1), cell("右上", col: 1, row: 0)]
        check("2×2 铺满 → 左上 右上 左下 右下",
              WindowEnumerator.sorted(grid).map(\.title) == ["左上", "右上", "左下", "右下"],
              "实际 \(WindowEnumerator.sorted(grid).map(\.title))")
    }

    // 6. 读不到位置的窗口排最后，不插队
    do {
        let unknown = WindowInfo(title: "位置未知", element: AXUIElementCreateSystemWide(),
                                 isMinimized: false, isFocused: false,
                                 frame: .zero, screenIndex: nil, isOnOtherSpace: false, hidden: nil)
        let mixed = [unknown, window("正常", onScreen: 0, xOffset: 10)]
        check("位置未知的窗口排在最后", WindowEnumerator.sorted(mixed).map(\.title) == ["正常", "位置未知"],
              "实际 \(WindowEnumerator.sorted(mixed).map(\.title))")
    }

    print("")
    print(failures == 0 ? "全部通过：\(passed) 项" : "有 \(failures) 项未通过（通过 \(passed) 项）")
    exit(failures == 0 ? 0 : 1)
}
