# 独立播放内核：续播保存与兼容恢复设计

## 状态与范围

**设计未实现，不能当作功能完成、测试通过或默认换核完成。**

本记录来自 2026-10-13 对 `codex/native-playback-core` 的只读审查。审查时 HEAD 为
`e8453cda6ec27736ab4c3212944e7d3b748b3ffc`；工作树另有其他代理的动作门禁、音频偏好及
队列启动修补。本文不修改生产代码、不新增续播测试、不运行完整 App、不读取用户媒体或真实偏好。
下列行号是记录时的定位辅助，后续应按方法名重新核实，不能把该工作树当作已提交的冻结版本。

正式默认仍为 MPV，native 仅内部 opt-in。当前 95 项完整 App 候选在
`Tools/NativeAppTests/NativeAppTestDriver.swift:88–89` 明确设置
`recordPlaybackHistory=false`、`recordRecentFiles=false`、`resumeLastPosition=false`。
该候选的准备检查或今后的正常整窗通过，都不能自动证明本设计的续播行为通过；较早 92 项
完整 App 与独立队列 54 项结果也不能覆盖这里的缺口。

记录时关键源码 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `iina/PlayerCore.swift` | `c0c69a4a99b0fd92a4bedda2aa86f453ca77a4f73b9073c477697004323a94e1` |
| `iina/NativePlayback/NativePlaybackSession.swift` | `aab38cba18651a86e7250e743a9af2e580ae50c67c3bc7ee150f937d6184d1af` |
| `Tools/NativeAppTests/NativeAppTestDriver.swift` | `f19d431cd18e08c9ba9c75ff33d2175d8214d74552352734c3d473993ad09e52` |

这是源码审查标识，不是这些文件已通过新同源完整验证的声明。

## 一、当前源码证据

### 保存入口缺失

- `iina/Preference.swift:870`：`resumeLastPosition` 默认 `true`。
- `iina/MPVController.swift:781–785`：旧内核使用 `Utility.watchLaterURL`，同一个偏好分别绑定
  `save-position-on-quit` 和 `resume-playback`。
- `iina/PlayerCore.swift:3822`：`savePlaybackPosition()` 遇 `isUsingNativePlayback` 立即返回。
  因此不仅不写 watch-later，也不更新该方法后半段的 LastPlayed 与缓存播放进度。
- `PlayerCore.shutdown():2128`、`stop():2340`：有 native transport 时直接退休并返回，
  跳过原 MPV 保存路径。
- `PlayerCore.openMediaURLs():1795` 与 `openMainWindow():1928`：真正打开新媒体时也直接退休
  旧 native session；没有对旧媒体进行保存。
- `PlayerCore.attemptNativeOpen():1300`，尤其 `1333–1338`：存在 watch-later 文件且允许续播时
  才触发兼容回退；首次 native 播放没有旧记录，因此不能靠这个门禁弥补关闭时的保存缺失。

`retireNativePlayback():1695` 同时服务于关窗、换片、列表切项和同片兼容交接，不能在其中
无条件保存。必须把退出原因作为独立意图区分。

### 显式队列的旧记录回退还会覆盖恢复位置

这条是额外的源码链路发现，**尚未通过实际播放复现，不得写成已修复**：

1. `attemptNativeOpen()` 在异步 inventory 中发现旧 watch-later。
2. 当前存在 `nativeQueue` 时调用 `handoffUnopenedNativeQueue():1202`。
3. 该方法构造 `NativeCompatibilityRestore(position: 0, rate: nativePreferredRate, ...)`。
4. 安装器让 MPV 加载选中项；MPV 可以正常读取其旧续播记录。
5. `fileLoaded():4093–4103` 又根据上述 restore 设置速度并执行 `seek(absoluteSecond: 0, ...)`，
   从而可能覆盖 MPV 刚恢复的位置／速度。

因此“遇旧记录就回退 MPV”目前只是一条准入策略，不能作为显式队列续播已兼容的证明。
实现前必须区分“尚未开始的新媒体，让 MPV 执行自己的恢复”和“已播放 native 媒体，恢复
本次捕获的真实快照”。不能为了处理前者删除后者的精确 seek 或 owner 验证。

### 预览与关窗的顺序

实际调用链：

```text
MainWindowController.windowWillClose
  -> invalidateChromeOnClose
  -> notifySidebarClosed
  -> QuickSettingViewController.sidebarDidClose
  -> VideoToolsViewController.stopPreview
  -> PlayerCore.finishNativePreview
  -> PlayerCore.stop
```

定位：`MainWindowController.swift:322,1599,2675`、`QuickSettingViewController.swift:487`、
`VideoToolsViewController.swift:1073`、`PlayerCore.swift:512`。
`finishNativePreview` 先清空 baseline，再向异步 worker 排入恢复命令；随后 `stop()` 可以在
恢复完成前到达。此时 `info.videoPosition` 仍可能是临时预览点，baseline 也已不在原字段中。
只在 `stop()` 读取当前 baseline 或 UI 缓存都不足以处理该顺序。

### 现有 query 不能直接用于马上退出

`NativePlaybackSession.captureCurrentState():284` 要求 request identity 未变且不是 terminal；
只在真实稳定播放／暂停／结束且不 preroll 时返回 `.ready`。`shutdown():384` 在主线程立即
设置 terminal、推进 identity，再在 worker reset。因此先调用 query 再立即 shutdown，其
结果可能必然变成 `.superseded`；不能靠放宽 query 检查把过期结果伪装成有效。

`publish():490` 的 UI 快照正常最多每 0.1 秒更新一次，且 seek／预览有独立命令队列。
缓存值不等于退出时的精确播放时钟；本设计不能把它声称为精确采点。

## 二、锁定 MPV 的实际保存语义

版本与归档来自 `other/playback_sources.sh:6,23–25`：MPV `0.38.0`，归档
`mpv-0.38.0.tar.gz`，SHA-256：

```text
86d9ef40b6058732f67b46d0bbda24a074fae860b3eaae05bab3145041303066
```

本轮只读核对本地归档确实匹配；以下未修改成员与该归档解出的成员逐字节哈希一致：

| 归档成员 | SHA-256 |
| --- | --- |
| `mpv-0.38.0/player/configfiles.c` | `506747a404834ccd9a6a7c900716fb50a01e90399d572799f52cbf62283c68d4` |
| `mpv-0.38.0/player/loadfile.c` | `ad19042854ac14b1c69c8fcacda00249256278cd86219e388dd7e2f2b223d241` |

同时检查候选播放库 build record 的补丁后 `player/command.c`；既有 unload/seek backport
只修改该文件后部 play-direction 回调，没有改下述保存入口。构建记录相对路径为
`build/native-av1-playback.7FMHum/playback-build-record/`，属于本机证据，不作为其他机器的构建依赖。

| 锁定源码位置 | 可确认的语义 |
| --- | --- |
| `player/command.c:5406–5412`，`cmd_quit` | 开启保存偏好或显式 quit-watch-later 时写记录 |
| `player/command.c:5634–5664`，`cmd_loadfile` | replace 等实际切换当前项的分支，在保存偏好开启时保存旧媒体 |
| `player/command.c:5419`、`:5477` | playlist-next/prev/play-index 不调用 watch-later 保存 |
| `player/command.c:5793–5805`，`cmd_stop` | 受 idle 模式与保存偏好约束；App 另有显式保存入口，不能只复制此分支 |
| `player/configfiles.c:305` | 有 playing 项才写；未知时间或不可 seek 不写 start；其他参数按 watch-later-options 与变更情况保存 |
| `player/configfiles.c:430` | resume 关闭时不加载；可选 mtime 检查；备份 start，避免污染下一文件 |
| `player/loadfile.c:1621,1778–1779` | 加载旧记录，成功 FILE_LOADED 附近消费它；加载失败不能等同于成功消费 |
| `player/configfiles.c:392` | 删除当前文件及相应父目录 redirect；不能随意把此范围移植成新保存器的全目录删除 |

自然 EOF 不主动创建续播记录；但 EOF 留窗后用户再关闭／退出的准确终点行为仍须真实 MPV
对照，不自行添加“超过某个百分比就删除”或固定减几秒规则。上述为源码证据，不是本轮
新跑过的 MPV 生命周期验收结果。

## 三、建议的最小兼容实现

第一切片仅补 **native 退出保存 → 标准 watch-later → MPV 实际恢复**，不同时实现第二套
永久数据库、完整 native watch-later 解析器或改变正式默认。

1. 引入不可变 `NativeResumeReceipt`，至少绑定 transport identity、旧 URL、媒体 generation、
   route、退出原因、保存请求 ID 和清理 epoch。在 reset owner、清 preview、推进 route 之前
   建立；路径相同不等于媒体相同。
2. 只有显式 close/stop、quit（此前未保存）、真正的新文件 replacement 产生保存请求。
   compatibility retirement、列表导航／选项切换不产生新记录。
3. Session 提供与退休 receipt 绑定的最终 worker 采点，位于 reset 之前；terminal 后只能把
   结果交给该保存请求，不能重新开放正常 query 或触发新播放。不可用时明确跳过，不能填零。
4. 正在预览使用同 owner 的原播放 baseline。`finishNativePreview` 在清 baseline 之前保留
   “正在恢复的 checkpoint”，直到实际恢复确认或显式用户导航取消。退出采点与该 checkpoint
   之间的选择必须可测试，而非依赖回调碰巧先后。
5. 写入 `Utility.watchLaterURL` 下 MPV 标准文件。`start=` 保持第一行，使用有限、非负、
   locale-independent 的数值；可写受支持且确实需要恢复的 `speed`。不写临时 A/B、预览状态、
   明文媒体路径或音量；每次打开音量归零仍独立执行。
6. 串行、原子发布，不跟随不可信 symlink，不覆盖未知的旧 MPV 配置、外部修改或其他 owner 的
   较新记录。已有记录的处理要有明确冲突结果，不能用“检查存在后直接覆盖”充当原子保证。
   I/O 失败应给出不含私人路径的诊断，不能卡住退出或删除旧记录。
7. 下一次单文件打开暂时沿用旧记录回退，交由 MPV 恢复／消费。显式队列须先修正上节所述
   `position: 0` 覆盖问题；未打开项不能伪装成“已有 native 真实快照”。
8. 更新现有列表进度缓存及 LastPlayed 时单独核对 owner 和清理 epoch，不能让旧文件异步结果
   改写新文件 UI 或复活用户刚清掉的最近记录。

此切片完成后，有续播记录的那一次仍可能使用 MPV。必须如实说明这个兼容边界；后续若需要
始终 native 恢复，应另做受限解析、旧配置退回、消费和完整验证，不靠删除旧记录解除准入限制。

## 四、不保存、清理与竞态边界

| 情况 | 要求 |
| --- | --- |
| 用户 stop／关窗 | 保存就绪旧媒体一次，再按原生命周期退出 |
| quit 未经过 stop | 保存一次；不阻塞主线程，不延长原退出门禁掩盖失败 |
| stop 后 quit／重复关窗 | 合并终止意图，不重复保存或用 idle 零值覆盖 |
| 真正 replacement | 旧 receipt 仅保存旧文件；不能修改新 info 或 LastPlayed |
| 同路径重开／多个 core | 校验媒体代次和写入顺序，旧回调不能覆盖新 owner |
| 同片 compatibility handoff | 本身不写；用户在 handoff 中关闭时另建立有效退出 receipt |
| handoff capture／retire／loaded／seek 中关闭 | 优先使用有效 owned restore；不得保存半加载 MPV 的默认零位置 |
| 列表 next／previous／select、自然 EOF 自动切项 | 保持旧内核不创建旧项记录的行为 |
| opening 未 ready、失败、位置不可用或非有限 | 不编造位置、不写零占位、不删除已有记录 |
| preview 活跃／恢复中 | 保存原播放 checkpoint，不保存临时循环位置；用户显式 seek 后须撤销旧 checkpoint |
| resumeLastPosition 关闭 | 不保存、不读取恢复；不擅自删除用户原有记录 |
| 排队保存中关闭 resumeLastPosition | 提交前重新核实偏好，已失效请求不能继续写 |
| 清除已保存进度 | 推进清理 epoch 并清理既有 watch-later，排队回调不得复活记录 |
| 清除历史／最近记录 | 遵守各自独立语义；阻止迟到的 LastPlayed 写入，不连带删 watch-later |
| 非预期现存文件、symlink、权限／磁盘错误 | 保留旧数据、准确报告失败，不为成功而扩大写入或删除范围 |

偏好与清理入口必须分清：

- `recordPlaybackHistory` 只控制 `HistoryController.add()` 的历史记录；见
  `HistoryController.swift:71` 和 `Preference.swift:47,841`。
- `recordRecentFiles` 是系统最近文件机制；见 `Preference.swift:48,842`。
- `resumeLastPosition` 控制续播，两者不能替代它，也不能因为关闭主页最近记录就默默停掉续播。
- `PrefUtilsViewController.clearWatchLaterBtnAction():127` 清理现有 watch-later 目录。
- `clearHistoryBtnAction():136` 与 `AppDelegate.clearRecentDocuments():1236` 处理历史／最近记录，
  后者显式清空 LastPlayed 路径及位置。新后台 writer 必须协调这些入口，而不能事后重新填回。

特别注意：`stop()` 当前会先清多个 owner；不得清完才试图读取 owned restore。
`nativeRetirementCompletion` 可能因新请求更新；保存 receipt 不能复用一个没有身份校验的
通用 completion 变量。保存完成也不能被用作复活旧播放动作的信号。

## 五、MD5 大小写与旧记录互操作

`Utility.mpvWatchLaterMd5():551` 调用 `String.md5`；后者到 `Extensions.swift:459,502` 的
实现生成小写十六进制。锁定 MPV 的 `player/configfiles.c:228` 用 `%02X`，生成大写文件名。
普通大小写不敏感 APFS 会隐藏差异，大小写敏感文件系统不会。

新写入必须采用明确的 MPV 规范，并对旧小写记录的读取／冲突处理做测试。还需覆盖
`Utility.playbackProgressFromWatchLater():560` 和 admission 的存在检查；不能只让新 writer
通过而使列表进度或旧配置准入失效。不要全局更改历史记录 MD5 主键造成重复历史或丢失关联。
不得用真实用户目录验证，不需要格式化磁盘；精确文件名的 policy 测试与受管、可清理的实际
大小写敏感 fixture 可分层验证，不能把前者冒充后者。

## 六、最小验收矩阵（全部待实现／待运行）

| 层次／建议入口 | 必须验证 |
| --- | --- |
| 新 `Tools/NativeResumePolicyTests` | 保存原因表、有限数值、正确文件名、冲突保留、原子发布失败、symlink、偏好与 clear epoch |
| 临时目录中的真实标准记录 | 首行兼容、实际 MPV start/speed 恢复、静音开片不变、FILE_LOADED 消费、加载失败保留、resume 禁用不消费 |
| 旧 MPV 记录互操作 | 保留未知多选项记录，不拆坏 filters/字幕等旧配置；大写、小写与冲突两个记录的明确策略 |
| 基于 `NativeGenericHandoffTests` 的实际 Session | 正常播放／暂停／seek 后 stop、close、quit、replacement；真实 worker 采点，不制造 ready |
| 真实 worker 屏障与 preview | 预览中关窗、finish 恢复排队时关窗、显式 seek 取消旧 checkpoint、自动隐藏不等于关窗 |
| 兼容交接四阶段 | capture、retire、FILE_LOADED、seek restore 中 stop/quit，不写默认零值，不重放取消动作 |
| 所有权与新媒体 | 不同文件替换、同路径重开、多个 core、旧结果晚到、stop 后 quit；保存和播放 completion 独立 |
| 显式 native 队列 | 旧记录准入后 MPV 真实续播不被零 seek 覆盖；列表手动切项与自然 EOF 不错误保存 |
| 实际 MPV 对照 | EOF 留窗后 close、直接 quit、replace 与普通列表导航；不凭猜测添加近尾删除规则 |
| 隔离偏好与清理 | 保存途中关闭 resume；清进度／清历史／清最近记录后迟到回调不复活相应数据 |
| 精确负控 | 逐项撤销 receipt、preview checkpoint、清理 epoch、只写旧 URL 等保护；要求完整预期失败集合，崩溃／超时不算有效负控 |
| 完整 App CI | 新增 resume=true 的独立隔离场景：preview→关窗→重开、替换、quit 后重启；原 95 项及队列断言不减少 |

测试必须只使用合成媒体、独立偏好域与临时 watch-later 目录，不能写用户 Application Support。
真正 App 产物继续用 `TestAppWorkspace`，不本地绕过 CI-only 完整 App 约定，不改正式安装、
系统权限、默认后端、签名、版本或发行资产。必须记录相同源码和生成物前后身份、子进程退出、
负控准确失败集合及清理结果；静态审查、编译和 policy 通过分别报告，不冒充完整恢复验收。

## 下一步

待本轮动作门禁／音频偏好／队列启动修补完成同源冻结后，单独冻结续播切片：先建立真实 MPV
语义对照和 policy 测试，再接 Session／Core／清理入口，最后新增完整 App 场景。
本文仅为下一块工作的入口，不是要求其他代理立即修改当前冻结生产文件。
