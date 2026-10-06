import ApplicationServices
import Cocoa

/// 辅助功能权限：检查、触发系统弹窗、跳到设置面板。
enum Accessibility {

    /// 当前进程是否已被授权。注意 TCC 认的是**进程身份**（bundle id + 签名），
    /// 不是二进制路径——所以裸 CLI 的授权很不稳定，正式形态必须是签名的 .app。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 触发系统授权弹窗。同一个进程只会弹一次，之后必须让用户自己去设置面板勾选。
    @discardableResult
    static func requestPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 直接跳到「隐私与安全性 → 辅助功能」。
    static func openSettingsPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
