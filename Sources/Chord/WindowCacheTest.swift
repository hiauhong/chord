import Cocoa

/// `--cache-test`：窗口缓存的合并逻辑自测。
///
/// 为什么这块值得单独测：它是"别的桌面上的窗口还能列出来"这件事的**全部逻辑**
/// （AX 的行为没法在单测里造，只能靠 `--watch-windows` 实地观察）。
/// 逻辑本身很小，但错了有两种难查的表现：重复列出一个窗口、或者把已关闭的
/// 窗口一直留在列表里（缓存里的 AX 元素在窗口关掉后读属性会报
/// `kAXErrorInvalidUIElement`，正是靠这个剔除）。
///
/// 用整数当"窗口"的替身：`same: ==`、`alive: { $0 != 0 }`（0 = 已经失效的元素），
/// 这样不需要辅助功能权限、也不需要真的开窗口。
func runCacheTestAndExit() -> Never {
    var passed = 0
    var failures: [String] = []

    func check(_ condition: Bool, _ name: String) {
        if condition { passed += 1 } else { failures.append(name) }
    }

    let alive: (Int) -> Bool = { $0 != 0 }
    let same: (Int, Int) -> Bool = { $0 == $1 }

    // 1. 别的桌面上的窗口（缓存里有、这次查不到）接在查到的后面
    do {
        let result = WindowEnumerator.mergeCache(fresh: [1, 2], cached: [3], same: same, alive: alive)
        check(result.shown == [1, 2, 3], "缓存里的窗口接在后面")
        check(result.cache == [1, 2, 3], "缓存被更新成合并后的")
    }

    // 2. 同一个窗口两边都有 → 只留一份，且用这次查到的那份（元素更新）
    do {
        let result = WindowEnumerator.mergeCache(fresh: [7, 8], cached: [7], same: same, alive: alive)
        check(result.shown == [7, 8], "同一个窗口不重复列出")
        check(result.cache == [7, 8], "缓存里不留旧的那份")
    }

    // 3. 缓存里已经失效的元素（窗口被关掉）剔除
    do {
        let result = WindowEnumerator.mergeCache(fresh: [1], cached: [0, 2], same: same, alive: alive)
        check(result.shown == [1, 2], "失效的缓存项不进列表")
        check(result.cache == [1, 2], "失效的缓存项也从缓存里清掉")
    }

    // 4. 空的两头
    do {
        let result = WindowEnumerator.mergeCache(fresh: [Int](), cached: [Int](), same: same, alive: alive)
        check(result.shown.isEmpty, "两边都空 → 空列表")
    }

    // 5. 缓存项顺序保持不变（列表顺序由 screenIndex 排序决定，但缓存项之间不能乱序）
    do {
        let result = WindowEnumerator.mergeCache(fresh: [9], cached: [4, 5, 6], same: same, alive: alive)
        check(result.shown == [9, 4, 5, 6], "缓存项之间保持原顺序")
    }

    // 6. 缓存里的窗口这次又查到了（比如切回它的桌面）→ 不算"其他桌面"，
    //    这一条由调用方用 `fresh.contains` 判断，这里只保证不重复。
    do {
        let result = WindowEnumerator.mergeCache(fresh: [1, 2, 3], cached: [1, 2, 3], same: same, alive: alive)
        check(result.shown == [1, 2, 3], "全部查得到时列表不变")
        check(result.cache == [1, 2, 3], "缓存不增长")
    }

    print("窗口缓存合并逻辑自测：")
    for failure in failures { print("  ❌ \(failure)") }
    if failures.isEmpty {
        print("全部通过：\(passed) 项")
        exit(0)
    }
    print("通过 \(passed) 项，失败 \(failures.count) 项")
    exit(1)
}
