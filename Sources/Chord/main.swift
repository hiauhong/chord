import Cocoa

// 运行模式：
//   默认            → GUI（菜单栏；开机自启那一次不弹配置窗，手动启动弹。
//                     未授权时配置窗顶部显示权限提示条，菜单栏图标带 ⚠️）
//   --login-launch / --manual-launch → 不改变行为，只强制「这次启动的来源」判定，
//                     让"开机自启不弹窗"两条分支都能在开发会话里验证（见 LaunchContext）
//   --self-test     → 命令行自检，结果打到 stdout，退出码 0/1/2
//   --dump-config   → 打印磁盘上的配置，供模型/持久化的机械验证
//   --seed-config   → 写入演示配置（幂等，已有配置不覆盖）
//   --normalize-config → 读进来再写回去（旧格式迁移 + 验证写回规范化）
//   --ui-metrics    → 不显示地实例化配置窗，量出布局要求的尺寸
//   --state-test    → 状态机自测（前进/回卷/下钻/提交），不需要任何权限
//   --drag-test     → 拖动排序自测（落点下标 / 组内顺序 / 跨组移动）
//   --drag-mouse-test → 拖动**起手**自测（合成鼠标事件；会短暂激活本进程抢一次焦点）
//   --screen-test   → 多屏窗口排序自测（不需要辅助功能权限）
//   --status        → 打印 app 自己写下的运行状态（回答 CLI 答不了的权限问题）
//   --window-order  → 打印 app 写下的窗口顺序诊断（真实窗口坐标与排序）
//   --render-hud [png] → 用合成状态把切换浮层渲成图片，检查窗口行的分列布局
//   --record-test   → 快捷键录制自测（待定不落盘 / 撞车再按交换 / Esc 取消）
//   --login-item [--enable|--disable] → 查看/切换登录项（开机自启）
//   --windows [app] → 按 AX 顺序打印窗口列表，验证"第 1 个是当前窗口"这个假设
//   --watch-windows [app] [--seconds N] [--raise N] → 持续观察窗口列表（含别的桌面上见过的）
//   --hidden-windows [app] [--switch 屏:桌] → 别的桌面上 AX 看不见的窗口（SkyLight 私有接口）
//   --cache-test    → 窗口缓存合并逻辑自测（去重 / 剔除已关闭 / 顺序），不需要权限
//   --reopen-test [app] [--force-reopen] → 跑「窗口全关时补发的那发 reopen」，验证能开回窗口
//   --render-chip [png] → 把 app 图标（含悬停角标）渲染成图片，供肉眼检查
//   --render-window [png] [--select N] → 把配置窗整体渲染成图片（--select 先选中第 N 行）
//   --render-recorder [png] → 把快捷键录制按钮的各个状态（绑定/录制/待定/撞车）渲成一张图

let arguments = CommandLine.arguments

if arguments.contains("--self-test") {
    runSelfTestInTerminal()
}
if arguments.contains("--dump-config") {
    runDumpConfigAndExit()
}
if arguments.contains("--seed-config") {
    runSeedConfigAndExit()
}
if arguments.contains("--normalize-config") {
    runNormalizeConfigAndExit()
}
if arguments.contains("--ui-metrics") {
    runUIMetricsAndExit()
}
if arguments.contains("--state-test") {
    runStateTestAndExit()
}
if arguments.contains("--windows") {
    runWindowDumpAndExit()
}
if arguments.contains("--reopen-test") {
    runReopenTestAndExit()
}
if arguments.contains("--watch-windows") {
    runWatchWindowsAndExit()
}
if arguments.contains("--hidden-windows") {
    runHiddenWindowsAndExit()
}
if arguments.contains("--cache-test") {
    runCacheTestAndExit()
}
if arguments.contains("--render-chip") {
    runRenderChipAndExit()
}
if arguments.contains("--render-recorder") {
    runRenderRecorderAndExit()
}
if arguments.contains("--render-window") {
    runRenderWindowAndExit()
}
if arguments.contains("--drag-test") {
    runDragTestAndExit()
}
if arguments.contains("--drag-mouse-test") {
    runDragMouseTestAndExit()
}
if arguments.contains("--screen-test") {
    runScreenTestAndExit()
}
if arguments.contains("--status") {
    runStatusAndExit()
}
if arguments.contains("--window-order") {
    runWindowOrderAndExit()
}
if arguments.contains("--render-hud") {
    runRenderHUDAndExit()
}
if arguments.contains("--record-test") {
    runRecordTestAndExit()
}
if arguments.contains("--login-item") {
    runLoginItemAndExit()
}

// 单实例闸门：**只拦 GUI 模式**（上面的命令行模式都要能在 app 跑着时照常运行，
// 整个诊断体系都建立在这上面）。跑两份 = 两个 tap 抢着吞键 + 两个浮层，见 SingleInstance。
if !SingleInstance.acquire() {
    if SingleInstance.otherInstanceIsRunning() { SingleInstance.askOtherToShowSettings() }
    AppStatus.log("已有实例在跑（单实例锁没拿到）→ 叫它弹配置窗，自己退出")
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
