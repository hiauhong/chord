import Cocoa

/// 把 app 自己的运行状态落地成文件。
///
/// 存在的理由很实际：**辅助功能权限的判定跟进程身份有关**。
/// 从 shell 直接跑 `Chord.app/Contents/MacOS/Chord` 时，TCC 看到的是父进程的身份，
/// 于是报"未授权"；而通过 `open` 启动的 .app 才是被用户授权的那一个。
/// 结果就是 `--self-test` 会给出误导性的结论（这个坑真的踩过：app 侧明明有权限、
/// tap 在工作、事件在流动，CLI 却一直说未授权）。
///
/// 把 app 自己的判断写进文件之后，`--status` 就能看到**它眼中**的真实状态。
enum AppStatus {

    /// 保留最近多少行，避免文件无限增长。
    private static let keepLines = 200

    static var fileURL: URL {
        ConfigStore.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent("status.log")
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"

        // 读-改-写要**串起来**：这个文件同时被 app 和各个命令行进程写（诊断体系就靠它），
        // 两个进程同时写时后写的会把先写的那行整段吞掉（实测：第二个实例那句
        // "已有实例在跑…"就是这么丢的）。flock 只在这一次读写期间持有，微秒级，
        // 而且进程死了内核会自动释放。
        let lockPath = fileURL.deletingLastPathComponent().appendingPathComponent("status.lock").path
        let lockDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_EX) }
        defer { if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) } }

        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(line.trimmingCharacters(in: .newlines))
        if lines.count > keepLines { lines = Array(lines.suffix(keepLines)) }

        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 窗口顺序诊断写到这里。**单独一个文件、不设行数上限**，
    /// 因为它可能很长（每个 app 的全部窗口）。
    static var windowOrderURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("window-order.txt")
    }

    static func writeWindowOrder(_ text: String) {
        try? text.write(to: windowOrderURL, atomically: true, encoding: .utf8)
    }

    static func recent(_ count: Int = 25) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init).suffix(count))
    }

    /// 一行写给日志用的环境描述。把**进程身份相关**的信息也带上，
    /// 免得下次又在"到底谁有权限"上绕圈。
    static func environmentSummary() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "（无 bundle —— 裸二进制，TCC 身份不稳定）"
        return "启动 bundleID=\(bundleID) 辅助功能=\(Accessibility.isTrusted ? "已授权" : "未授权")"
            + " 开机自启=\(LaunchAtLogin.description)"
            + " 这次来源=\(LaunchContext.description)"
            + " pid=\(ProcessInfo.processInfo.processIdentifier)"
    }
}
