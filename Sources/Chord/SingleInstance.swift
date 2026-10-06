import Cocoa

/// 同一个 app **只允许跑一份**。
///
/// 菜单栏工具跑两份的后果不是"多一个图标"这么轻：
///   · **两个 CGEventTap 抢着吞键** —— 键被先建的那个吞掉，后一个只看到一半事件，
///     "按住修饰键 + 重复按组键"这套交互直接随缘；
///   · 两个浮层、两份窗口缓存巡检（每 5 秒各查一遍所有桌面）；
///   · 两个「提交切换」各自去 activate，谁赢看心情。
///
/// 为什么需要显式做这件事：**从 Finder/`open` 启动时 LaunchServices 本来就会复用**，
/// 但绕过它的路子很常见 —— 直接跑 `Chord.app/Contents/MacOS/Chord`（开发就是这个）、
/// 或者两份拷贝（`build/` 一份、`/Applications` 一份，同一个 bundle id 但是两个路径）。
/// 实测：直接跑 bundle 里的二进制，GUI 模式确实能起出第二份。
///
/// 两道闸门，各管一件事：
///   · `flock` 占锁 —— **判定的权威**，内核在进程退出时自动释放，没有竞态
///     （同时启动两份也只有一个能拿到）；
///   · 按 bundle id 找另一个实例 —— 用来**叫它把配置窗弹出来**：不然用户双击一下
///     什么反应都没有，看着像"启动失败了"。
enum SingleInstance {

    /// 叫另一个实例弹配置窗的通知名（同 bundle id 的实例都能收到，无需任何权限）。
    static let showSettingsNotification = Notification.Name("com.hiauhong.chord.showSettings")

    private static var lockDescriptor: Int32 = -1

    /// 抢单实例锁。拿到了返回 true（并一直持有到进程退出）；没拿到说明已经有一份在跑。
    ///
    /// **只给 GUI 模式用**：`--self-test` / `--ui-metrics` 这些命令行模式必须能在 app
    /// 跑着的时候照常运行（整个诊断体系都建立在这一点上）。
    static func acquire() -> Bool {
        let directory = ConfigStore.defaultFileURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("chord.lock").path

        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }        // 打不开锁文件就别拦着自己
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor                         // 持有到进程结束
        return true
    }

    /// 已经有实例在跑吗（除自己以外）。
    static func otherInstanceIsRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// 叫已经跑着的那一份把配置窗弹出来。
    static func askOtherToShowSettings() {
        DistributedNotificationCenter.default().postNotificationName(
            showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
