# 剪辑预览随控制条自动隐藏而中断的修复交接

## 范围与根因

基于 `cc8daee7`（`v0.2.65` / build `76`），目标 `v0.2.66` / build `77`。
用户在 `v0.2.45`、`v0.2.54`、`v0.2.64` 三轮修复后仍反馈「剪辑预览一直不行」。
本轮复盘 Codex 的完整会话、三次修复与用户截图，并在本机用独立 AppKit 程序实测后定位：

- Movist 风格界面（`oscPosition == .bottom`，当前默认）把 `sideBarView` 纳入
  `MainWindowController.visibleChromeViews`。指针在画面上静止 `controlBarAutoHideTimeout`
  （默认 2.5 s）后，`hideUI()` 把侧栏随控制条一起淡出，并在动画结束时置 `isHidden = true`。
- AppKit 把祖先视图被隐藏视为视图控制器消失：实测 `isHidden = true` 会触发
  `viewWillDisappear` / `viewDidDisappear`，取消隐藏触发 `viewWillAppear` / `viewDidAppear`，
  只改 `alphaValue` 不触发。
- `QuickSettingViewController.viewDidDisappear()` 原先无条件执行
  `setPlaybackControlsVisible(false)` 与 `stopPreview()`：预览被取消，播放器被恢复到预览前的
  位置与暂停状态。鼠标一动，`showUI()` 取消隐藏，`viewDidAppear` 再次把面板标记为可见，
  自动预览 350 ms 后重新开始。于是预览只在鼠标持续移动或停留在面板上时存在；
  用户把指针移到画面上观看约 2.5 s，预览就消失并跳回原位，这正是「不会自动预览」的体感。
- 既有实播回归 `Tools/ClipPreviewLiveTests` 只覆盖 `removeFromSuperview`，从未隐藏父视图，
  所以三轮修复都在 CI 通过而用户仍然失败。旧 Web 版 Local Video Cutter 的预览是独立进程，
  与本播放器无关。

本机 `/Applications` 内仍是 `v0.2.48` / build `59`（最后使用 2026-09-29），用户后续是在
M4 Max 上测试；本机没有辅助功能权限，不能用系统级鼠标事件驱动正式 App，
因此验证手段是编译生产 `QuickSettingViewController` 生命周期、生产工具面板与播放方法的实播 harness。

## 修复

- `QuickSettingViewController.viewDidDisappear` 增加 `isHiddenWithPlayerChrome` 守卫：
  视图仍附着在窗口、`mainWindow.sideBarStatus == .settings`、`mainWindow.sidebarAutoHidden`
  为真，且沿父视图链确有 `isHidden` 的视图时直接返回，不停止预览、不改可见状态。
- `hideSideBar` 先把状态置为 `.hidden` 再移除子视图，真正关闭仍会停止预览并恢复快照。
  窗口关闭、切到播放列表、切换标签、切换素材与更新屏障等路径不变。
- `MainWindowController.sidebarAutoHidden` 改为 `private(set)`，仅供只读。
- 独立评审发现守卫会带来新泄漏：侧栏仍处于自动隐藏时关闭窗口（Cmd+W）、用快捷键关闭侧栏或
  退出裁剪模式，AppKit 不会为已经「消失」的视图再回调一次 `viewDidDisappear`，预览状态与
  `playbackControlsVisible` 会残留，下一次载入新文件会把新文件开头当成预览区间循环。
  因此新增 `QuickSettingViewController.sidebarDidClose()`，由 `hideSideBar` 完成块、
  `invalidateChromeOnClose`（窗口关闭）与 `exitInteractiveMode` 在原状态为 `.settings` 时
  显式调用；它幂等，与正常可见路径的 `viewDidDisappear` 重复触发无害。
- AppKit 在这些回调内部的 `isHiddenOrHasHiddenAncestor` 是过期缓存（实测隐藏时仍为 `false`，
  取消隐藏时仍为 `true`），守卫因此检查实际的 `isHidden` 标志。
- 不修改导出、下载器、媒体、用户设置、更新源或签名身份。

## 同轮修复的其他预览缺陷

独立评审（四个视角分别搜索、每项再由独立 agent 反驳）在 `cc8daee7` 上确认了下列同样会让
用户觉得「预览不行」的问题，本轮一并修复，均有生产代码负对照：

- **载入新文件时预览被第二个观察者取消**：`MainWindowController` 在 `.iinaFileLoaded` 先
  `reload()` 工具页（非强制刷新，已排好自动预览），随后面板自身的观察者 `refreshCurrentMedia(force: true)`
  在源未变的情况下再次 `stopPreview()`，把刚排好的 350 ms 定时器取消。现在源未变且预览已排队或
  运行中时跳过重置（`previewInFlight`）。用例 `media-reload`，负对照 `--controller-ref cc8daee7`。
- **打开剪辑页跳回片头**：默认区间在文件载入时写成「载入时刻位置 + 5 s」（通常 00:00），用户看到
  12:34 才打开剪辑页时自动预览却从 00:00 开始循环。现在面板变为可见或切回剪辑页时，若区间从未被
  用户编辑（`rangeIsUntouched`），重新锚定到当前播放位置；`controlTextDidChange`、设为起点／终点与
  键盘 A/B 会清除该状态。用例 `anchor`，负对照 `--controller-ref cc8daee7`。
- **逐字输入时来回跳**：`"1:"`、`"1:30."` 等中间无效状态原先立即 `stopPreview()`，把播放器拉回
  预览前位置并恢复暂停，下一个有效字符又跳到新起点。现在无效中间态只清除 A/B 循环并保留快照，
  画面既不跳回也不重复旧区间；有效后继续预览，「停止预览」或关闭面板仍恢复原状态。
  用例 `invalid` 已按新语义改写。
- **中文输入法全角标点**：`１．５`、`1：30。5` 这类输入原先永远解析失败。`parseTimestamp` 现在先把
  「。」映射为「.」，再做全角到半角转换。用例 `fullwidth`。
- **精确 seek 落点容差**：从 `time-pos` 捕获并四舍五入到微秒的起点，在 23.976／29.97／59.94 fps
  等 1001 基帧率下约有三分之一会比真实帧 PTS 高不到 1 µs；mpv 的精确 seek 允许显示比目标早至多
  5 ms 的帧，于是落点位置略小于 A，`contains` 判定失败，三次纠正后循环被挂起并暂停，`resume()` 又
  永远拒绝恢复。现在 `VideoToolsLoopRange.admits` 对 A 侧允许 10 ms 落点容差，纠正逻辑读取原始
  `time-pos`（不再在 eof-reached 时用时长替代），暂停在区间最后一帧视为区间内，显式 `resume()` 会重置
  挂起状态给循环新的恢复预算。用例 `landing`，负对照 `--core-ref cc8daee7`。
- **输入框内按 Return**：评审实验表明真实按键会交给 field editor 而不会触发默认按钮，但本轮仍去掉
  「确定并剪辑」的 Return 快捷键，改为在起止输入框内按 Return 立即预览，导出只能显式点击。
- **画面上的提示**：预览开始与结束时在画面上发 OSD（`videotools.preview.active` / 新增
  `videotools.preview.stopped`），延迟 0.4 s 发送以免被 seek／resume 的 OSD 立即覆盖；
  控制条隐藏时也能看到正在预览哪个区间。

评审确认但本轮未改、留作后续的问题：侧栏打开时单击画面会关闭面板并恢复预览前位置；
校验错误会把任务详情卡滚入视野、把起止输入框滚出可视区约 500 点；Movist 风格设置侧栏 400 点限高
使「终点」一行恰在剪辑页折叠线附近，英文界面会被切掉一半。

## 回归入口

```sh
python3 -B Tools/ClipPreviewLiveTests/run.py
python3 -B Tools/ClipPreviewLiveTests/run.py --case chrome-autohide
python3 -B Tools/ClipPreviewLiveTests/run.py --parent-ref cc8daee7 --case chrome-autohide
python3 -B Tools/ClipPreviewLiveTests/run.py --controller-ref cc8daee7 --case media-reload
python3 -B Tools/ClipPreviewLiveTests/run.py --controller-ref cc8daee7 --case anchor
python3 -B Tools/ClipPreviewLiveTests/run.py --core-ref cc8daee7 --case landing
bash Tools/VideoToolsTests/run.sh
bash Tools/PlayerChromeTests/run.sh
bash Tools/PlayerChromeLifecycleTests/run.sh
bash Tools/PlayerChromeIntegrationTests/run.sh
bash Tools/WindowLifecycleTests/run.sh
```

新增 `chrome-autohide` 用例：真实 libmpv 预览运行中隐藏已附着的生产父视图，断言循环区间、
未暂停、快照保留且画面继续推进；取消隐藏后不重启、不重新 seek；再按真实关闭顺序
（先 `.hidden`、detach、再 `sidebarDidClose()`）断言预览停止并恢复暂停位置；最后在侧栏仍被
隐藏时执行同样的关闭顺序，并模拟 `refreshCurrentMedia(force: true)` 的媒体重载，断言预览不会复活。`--parent-ref <commit>` 用旧版
`QuickSettingViewController` 作负对照；对 `cc8daee7` 预期在「Auto-hidden player chrome keeps
the temporary preview range playing」失败，证明用例捕获的正是该缺陷。`--controller-ref` 与
`--core-ref` 同理分别替换旧版工具面板控制器与旧版 `PlayerCore` 播放方法。

## 本地验收

本机（Apple Silicon，macOS 26.7.1，仓库锁定的 libmpv 软件解码／渲染，无 Xcode，仅 CommandLineTools）：

- `ClipPreviewLiveTests` 全部 14 条用例 **324 项断言通过**，渲染 306 帧。早期单跑 `chrome-autohide`
  时有两次在「等待 seek 结束」3 秒上限超时，状态诊断显示区间、快照与播放均正常，发生在并行评审
  agent 占用 CPU 时；加入 `seeking` / `pause` 时间线诊断后连续 7 次及完整套件未再出现，无法排除负载因素。
- 负对照均按预期失败，证明用例捕获的正是对应缺陷：
  `--parent-ref cc8daee7 --case chrome-autohide` 失败于「Auto-hidden player chrome keeps the temporary
  preview range playing」（隐藏后区间为空、已暂停、快照丢弃、位置回到 0.267 s）；
  `--controller-ref cc8daee7 --case media-reload` 失败于「The forced refresh of the unchanged source keeps
  the scheduled automatic preview」；`--controller-ref cc8daee7 --case anchor` 失败于「Revealing the clip
  tab anchors the untouched default range at the current position」；`--core-ref cc8daee7 --case landing`
  失败于「A landing microseconds before the marker is accepted without corrections」，实测旧版
  `time-pos=0.033366667`、`failures: 3, suspended: true`，即真实 libmpv 下循环确实被挂起。
- `PlayerChromeLifecycleTests` 169 项（含新增：空闲隐藏不通知面板、显式关闭只通知一次、
  关闭播放列表不通知设置面板、控制条隐藏时关闭窗口仍通知且重复调用不重复）及 4 项全屏源码接线通过。
- `PlayerChromeIntegrationTests` 618 项、`PlayerChromeTests` 214 项、`PlayerChromeInteractionTests` 40 项、
  `WindowLifecycleTests` 181 项通过。
- `VideoToolsTests` 三语各 938 项（含新增 `admits` 落点容差检查）、旋转协调 77 项、任务管理三语各 132 项通过。
- `ClipPreviewNavigationTests` 310 项、`PlaybackModeLiveTests` 58 项、`PlaybackLifecycleTests` 76 项通过，
  确认提取 `PlayerCore` 方法的其他套件不受 `resume()` / `videoToolsEnforceLoopBounds` 改动影响。

拼写检查使用与 CI 相同的 `typos` 1.50.2（隔离 venv）对全仓库通过。

## 发布状态

生产提交 `f142348c`，标签 `v0.2.66`（build `77`）。拼写 CI `37592727262` 与主线 CI `37592727296`
（含同一提交的全部实播、原生面板、viewport、完整 App 与升级安装步骤）均成功。

标签 CI `37592734061` 首轮在既有步骤「Test real video picture zoom and pan」失败：
`FAIL: The player request exceeded its deadline`，最后完整样本 `reset shortcut; center=319.5,161.5`，
期望 `179.5`。该测试不涉及本轮改动的任何文件；主线流水线在同一提交上两分钟前刚通过同一步骤，
本机 `CHENGYING_ALLOW_CI_GL_SKIP=1 VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh`
148 项通过，渲染 53 帧。Codex 在 v0.2.45 与 v0.2.63 的交接中记录过同一测试在云端的偶发像素方向／时序失败。
按既有做法只重跑失败的 job（attempt 2），不改标签、不改测试断言、不发布未通过的构建。

### 正式交付

`v0.2.66` / build `77` 已于 `2026-10-07T09:50:31Z`（北京时间 **2026-10-07 17:50:31**）正式发布，
标签对应 `f142348c132f10088e7bcc19b286c824fe6700f2`，非草稿、非预发布。
标签 CI `37592734061` 第二次执行 `build-apple-silicon`、`media-helper-tests`、`publish-release` 全部成功，
发布 job `112732472948` 于 `2026-10-07T09:50:37Z` 完成；首轮失败的 viewport 步骤重跑后通过，未改标签或断言。

本机随后不使用任何登录态与 API 做独立匿名核验（仅 HTML 重定向与直接下载）：

- `releases/latest` 匿名重定向到 `releases/tag/v0.2.66`。
- 已安装客户端使用的 feed `releases/latest/download/appcast.xml` 返回单条项目，
  `sparkle:version` 77、`sparkle:shortVersionString` 0.2.66，enclosure 指向本版完整 DMG，长度 `168877907`，
  带 Ed25519 enclosure 与文件签名。
- 完整 DMG 匿名下载 `168877907` 字节，SHA-256
  `173ad3d08110daf6a80110939981404648e58f48167b7fd536e7169e686177df`，与公开 `.sha256` 资产及 feed 长度一致。
- 从 build `76` 的增量包匿名下载 `1267974` 字节，SHA-256
  `2971fbe969e083396a5bc60252c0baab7a9edce4cf3eae88c6b6729ec51ad58e`，与公开 `.sha256` 及 feed 长度一致。
- 发布资产共 8 项：DMG、增量包、各自 `.sha256`、签名 `appcast.xml`、发行源码包及其 `.sha256`、第三方源码清单。

[正式版本](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.66)
与[发布流水线](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/37592734061)。
本机正式安装（仍为 v0.2.48）、用户媒体与偏好未覆盖；未操作真实站点账号；
Ed25519 公钥连续性与增量全树还原由标签流水线既有门禁验证，本机未重复。

## 独立评审要点

三个独立评审（AppKit 生命周期、控制条路径、预览状态机）均确认根因；两项反驳意见已在本轮修正：
早期版本的守卫依赖回调内部过期的 `isHiddenOrHasHiddenAncestor`，以及隐藏状态下关闭导致的泄漏。
其余提醒记录如下，均未在本轮改动：

- 侧栏打开时单击画面会调用 `hideSideBar()`（`MainWindowController.mouseDown`），关闭面板并按设计恢复
  预览前的位置与暂停状态。用户若用单击画面来暂停预览，会看到画面跳回原位；这是既有的
  「关闭面板即结束临时预览」语义，不是随机中断，可作为后续体验议题讨论。
- `sidebarAutoHidden` 置回 `false` 的每条路径都同时递增 `chromeAnimationGeneration`，否则
  `hideUI` 的完成块可能在标志为 `false` 时隐藏侧栏并重新引入本缺陷；修改这些路径时需保持该不变量。
- 控制条已隐藏时最小化窗口不会再触发 `viewDidDisappear`，预览会在最小化期间继续循环；
  控制条可见时最小化仍会停止并在恢复后重新预览。两者不一致但影响很小。
- 本机已安装 App 为 `v0.2.48`，评审与修复均未在正式 App 内以系统级事件端到端复现。

## 限制

- 未以系统级鼠标事件在正式 App 中验证；harness 直接设置 `isHidden`，对应 `hideUI` 动画结束时的状态。
- 本机正式安装仍为 `v0.2.48`，本轮未覆盖；用户 M4 Max 上的版本未知，测试前请确认已更新到本版。
- 设置面板在 Movist 风格下仍限高 400 点：剪辑页需要滚动才能看到「终点」，预览入口固定在底部卡片。
  这是独立的布局议题，本轮未改动。
