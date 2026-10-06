import ServiceManagement

/// 开机自启（登录项）。
///
/// 用 macOS 13 起的 `SMAppService`，而不是老的 `LSSharedFileList`
/// （后者早已废弃，且在新系统上行为不一致）。
///
/// 两个实际要注意的点：
///   1. `register()` 成功不等于"已生效"——系统可能把它挂成
///      `requiresApproval`，要用户去「系统设置 → 通用 → 登录项」里点一下。
///      所以状态一律以 `status` 为准，而不是以调用是否抛错为准。
///   2. 登录项记的是**这个 .app 的路径**。开发构建在 `build/` 下，
///      把 .app 挪走（或重新构建到别的路径）会让登录项指向不存在的位置，
///      系统会在登录项列表里标成"找不到"。
///
/// 另外一条常被问到的：**登录项不需要、也带不了"静默启动"参数**。
/// `mainApp` 注册的就是这个 .app 本身，系统打开它时命令行是空的（BTM 记录里也只有 URL）；
/// "这次是登录项拉的"由 `kAEOpenApplication` 事件里的 `keyAELaunchedAsLogInItem` 告诉进程
/// —— 那才是系统为这件事准备的信号，见 `LaunchContext`。能带参数的是
/// `SMAppService.agent(plistName:)` 那条 LaunchAgent 路线（`ProgramArguments` 写在
/// bundle 内的 launchd plist 里），但那是给没有 UI 的后台服务准备的，而且参数是**注册时写死**
/// 的：写死就等于"用户双击那次也静默"，把"双击 = 我要配置"这个信号一起丢了。
enum LaunchAtLogin {

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// 给人看的状态描述。
    static var description: String {
        switch status {
        case .notRegistered: return "未开启"
        case .enabled: return "已开启"
        case .requiresApproval: return "已注册，等你在系统设置里批准"
        // 实测：首次注册**之前**就是 notFound，注册后变 enabled、注销后变 notRegistered。
        // 所以它既可能是"还没注册过"，也可能是".app 被移走了"，措辞要覆盖两种。
        case .notFound: return "系统暂时定位不到这个 .app（首次注册前会这样；.app 被移动也会）"
        @unknown default: return "未知(rawValue \(status.rawValue))"
        }
    }

    /// 尝试开启/关闭。返回是否操作成功（不代表已生效，生效与否看 `status`）。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<String, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(description)
        } catch {
            return .failure(error)
        }
    }
}
