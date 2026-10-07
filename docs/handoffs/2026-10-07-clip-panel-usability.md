# 剪辑面板可用性修补交接（单击画面、校验提示、面板高度）

## 范围

基于 `4deb3693`（`v0.2.66` / build `77`），目标 `v0.2.67` / build `78`。
用户要求把 [剪辑预览自动隐藏交接](2026-10-07-clip-preview-chrome-autohide.md) 中「评审确认但未改」的
三个问题一并修复并发布。不改导出、下载器、媒体、用户设置、更新源或签名身份。

## 修复

- **单击画面不再关掉工具面板**：原先侧栏打开时单击画面一律 `hideSideBar()`，剪辑面板随之关闭并按
  「关闭即结束临时预览」恢复到预览前位置。新增 `MainWindowController.sidebarDismissesOnVideoClick`：
  设置侧栏停在「工具」页时单击画面只结束输入框编辑（`makeFirstResponder(nil)`），事件继续走原有的
  单击动作（默认 `hideOSC`，由用户偏好决定），面板与预览保持。播放列表、其他设置页以及自动隐藏中的
  非工具页保留「点击画面关闭侧栏」的既有行为。
- **校验错误不再把输入框滚出视野**：`showValidationError` 不再调用 `revealTaskDetails()`；短校验信息
  以红色显示在固定底部卡片的 `previewStatusLabel`（粘性，直到下一次编辑、设点、切换模式、开始预览、
  换片或启动任务才清除），`statusLabel` 同时保留原文案供任务详情卡与既有测试读取。任务失败与导出启动
  仍滚动到详情卡。
- **设置面板由 400 点改为 600 点固定高度**：新增 `SettingsSidebarHeight = 600`，替换原来五处硬编码
  `400`（首选高度、最大高度与布局刷新）。窗口不够高时仍由既有 `>= 252` 与底部控制条约束收缩；
  播放列表的可拖动高度与记忆逻辑不变。实测 600 点下剪辑页的起点、终点、定位分段与提示全部在折叠线以上。

## 回归入口

```sh
bash Tools/PlayerChromeLifecycleTests/run.sh
bash Tools/PlayerChromeIntegrationTests/run.sh
bash Tools/PlayerChromeTests/run.sh
bash Tools/PlayerChromeInteractionTests/run.sh
bash Tools/WindowLifecycleTests/run.sh
bash Tools/VideoToolsTests/run.sh
python3 -B Tools/ClipPreviewLiveTests/run.py
python3 -B Tools/ClipPreviewNavigationTests/run.py
```

新增断言：生命周期测试覆盖隐藏／播放列表／普通设置页／工具页／自动隐藏的工具页五种状态下
`sidebarDismissesOnVideoClick` 的判定；集成布局测试把设置侧栏期望高度改为 `SettingsSidebarHeight`
并断言其为 600；原生面板测试在 400 点可视高度下触发「终点早于起点」校验，断言红色提示出现在固定卡片、
`statusLabel` 同步记录、起点输入框仍在可视区且文档未滚动，编辑后提示清除。

## 本地验收

本机（Apple Silicon，macOS 26.7.1，无 Xcode）：

- `PlayerChromeLifecycleTests` 174 项（新增 5 项单击判定）及 4 项全屏源码接线通过。
- `PlayerChromeIntegrationTests` 618 项与独立重启 4 项通过，设置侧栏实际高度 600；
  `PlayerChromeTests` 214 项、`PlayerChromeInteractionTests` 40 项、`WindowLifecycleTests` 181 项通过。
- `VideoToolsTests` 三语各 942 项（含新增校验提示 4 项与改写的终点早于起点断言）、旋转协调 77 项、
  任务管理三语各 132 项通过。
- `ClipPreviewLiveTests` 14 条用例 324 项断言通过（真实 libmpv）；`ClipPreviewNavigationTests` 310 项通过。
- 首轮生命周期测试替身缺少 `SettingsSidebarHeight`、原生测试仍期望通用的无效提示，均只改测试，不改生产逻辑。
- `typos` 1.50.2 对改动文件通过。

## 发布状态

生产提交 `0d9b62af`，标签 `v0.2.67`（build `78`）。拼写 CI `37606094575` 成功。

标签 CI `37606110769` 首轮 `build-apple-silicon`（全部 Swift 回归、完整 App、签名安装／重启与增量验证）成功，
`media-helper-tests` 失败于 Python helper 的 `tests/test_conversion.py::test_large_input_pts_does_not_prematurely_complete_progress`
（`assert all(progress <= 99 ...)`，其余 319 项通过）。该测试与本轮 Swift 改动无关：worker 在任务锁内同时写入
`completed` 与 `100.0`，测试在「线程仍存活」与「worker 退出」之间读到的完成快照被当成提前报 100%。
只重跑失败 job（attempt 2）后 `media-helper-tests` 与 `publish-release` 成功；测试本身已另行修正为只记录
运行中的采样（提交 `1eb1e9bb`，本机 45 项通过、ruff 通过），不改 helper 生产逻辑。

主线 `0d9b62af` 的运行 `37606094620` 因随后推送 `1eb1e9bb` 被并发策略取消；`1eb1e9bb` 的主线运行
`37610343190` 首轮再次在既有「Test real video picture zoom and pan」步骤超时（与 v0.2.66 标签首轮相同的
`The player request exceeded its deadline`，软件渲染 4K 重绘未在 8 秒内到达）。本机该测试两次 148 项通过。
为降低云端误报，`Tools/VideoViewportTests/Live/main.swift` 的单次采样共享上限由 8 秒放宽到 20 秒，
不改任何像素、方向、尺寸或窗口断言，90 秒外部看门狗不变；主线失败 job 已重跑。

### 正式交付

`v0.2.67` / build `78` 已于 `2026-10-07T11:22:35Z`（北京时间 **2026-10-07 19:22:35**）正式发布，
非草稿、非预发布，发布 job `112766304696` 于 `2026-10-07T11:22:41Z` 完成。本机不使用登录态与 API 的匿名核验：

- `releases/latest` 匿名重定向到 `releases/tag/v0.2.67`。
- 已安装客户端的 feed 返回单条项目：`sparkle:version` 78、`sparkle:shortVersionString` 0.2.67，
  enclosure 指向本版完整 DMG，长度 `168971816`，带 Ed25519 签名。
- 完整 DMG 匿名下载 `168971816` 字节，SHA-256
  `6e278201ffc6875a3b5e12c9264789e996576244afb2c1d62ad82f24e4bcc11c`，与公开 `.sha256` 及 feed 长度一致。
- 从 build `77` 的增量包匿名下载 `1068742` 字节，SHA-256
  `a56a5ab72a0f51ac23d24c73bae64beb0c86511adce877bb9f6212c348f4769a`，与公开 `.sha256` 及 feed 长度一致。
- 发布资产共 8 项（DMG、增量包、各自 `.sha256`、签名 `appcast.xml`、发行源码包及其 `.sha256`、第三方源码清单）。

[正式版本](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.67)
与[发布流水线](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/37606110769)。
本机正式安装（仍为 v0.2.48）、用户媒体与偏好未覆盖；Ed25519 公钥连续性与增量全树还原由标签流水线既有门禁验证。

## 限制

- 单击画面的实际 AppKit 事件流（`mouseDown` 消费与 `mouseUp` 分支）未在本机以系统级事件端到端验证，
  以可提取的判定属性加生命周期测试覆盖；本机正式安装仍为 `v0.2.48`。
- 600 点是固定值，不提供设置面板的拖动与记忆；如需与播放列表一致的可拖动高度属后续议题。
