# 独立播放内核迁移：第一阶段

## 状态与范围

用户于 2026-10-12 明确要求实际替换播放内核。本阶段开始于当天，验证跨至
2026-10-13，工作分支为 `codex/native-playback-core`，基于 `ee83d00a`。

**换核尚未完成，不是已发布版本。** 新后端已加入 Xcode 编译工程，能独立解码、同步播放
音视频和呈现实际画面。`PlayerCore` 与主窗口正在接入严格受限的内部 native 路由；
正式默认、字幕及剪辑预览仍使用 libmpv。
没有改变默认播放路径、版本号、用户偏好、已安装 App、更新源或签名身份。
不要仅因新文件进入编译工程，或下述测试通过，就宣布正式播放器已经换核。

实现路线是独立的 FFmpeg demux/decode → CoreMedia samples →
`AVSampleBufferVideoRenderer` / `AVSampleBufferAudioRenderer` → 共享
`AVSampleBufferRenderSynchronizer` 时钟。新后端不调用 mpv，也不是套用 AVPlayer。
macOS 14 及以后统一操作 display layer 的 `sampleBufferRenderer`，不混用两套队列 API；
较早系统保留 display layer 队列路径，当前仅通过部署目标编译，未做旧系统运行验收。
参考前一轮 REA 研究的高层职责划分；未复制 Movist Pro 的代码、反编译输出、二进制或资源。
不声称已经得到 Movist 的同一内核或性能。

## 主窗口接入切片（同日继续，尚未完成 App 验收）

内部环境变量 `CHENGYING_NATIVE_PLAYBACK=1` 才会尝试新路径；没有新增面向用户的默认开关。
只有从未向 mpv 发过媒体命令的 core、单个本地 SDR 视频、明确 SAR、单视频轨／最多一音轨、
无内嵌字幕／章节和不支持的定制配置才准入。自动同目录播放列表、外部字幕搜索与已有续播
状态不能静默丢失，因此检测到这些需求时使用兼容路径。一次回退后该 core 不再进入 native；
这不是任意两个活跃后端之间的无缝切换实现。

- 新 `PlaybackBackend` 类型接口保留 MPV 原命令语义，并接入独立 session。
  volume/rate/连续相对 seek/pause 有接受中的命令状态，快速连按不会反复取同一个旧 UI 快照。
  精确 A/B／预览时间读取另有异步、代次校验的 `captureCurrentState`，不阻塞主线程。
- `NativePlaybackSurface` 挂真实 display layer，处理 SAR、四向旋转、裁切、backing scale、
  zoom/pan。`VideoView` 原生路径不构造 `ViewLayer`／OpenGL、不启动 CVDisplayLink；
  主窗口使用明确的 resize、backing 和 redraw 分派。
- 设置、文件列表、未迁移快捷键／检查器暂先显式回到兼容内核；同一 URL 的暂停、时间、
  音量和速度恢复经过实际 MPV seek 完成检查后才执行动作，换片／停止取消旧动作。
  不把这种回退说成新内核已经支持字幕、剪辑预览和所有工具。
- MPV 媒体事件同时检查接收及主线程投递时的路由代次；首次兼容加载等待 `START_FILE`，
  不让初始化积压事件冒充新媒体。保留真实 shutdown、hook continuation 和错误诊断。
  修复属性插件异步回调持有临时 C 指针，以及没有 GL context 的 idle MPV 退出清理。
- metadata 增加真实轨道／章节清单、SAR 和 HDR 分类。容器 SAR 与码流不同的真实测试
  暴露了比例优先级错误，已统一按容器 override；未知 SAR 不是默认假定为方形像素。

新增本机验证：surface **106/0**、生产 VideoView 边界 **28/0**、transport **116/0**、
MPV 事件路由 ASan/TSan 各 **85 项**及两个预期失败负对照；窗口生命周期 **188/0**。
其中 ViewLayer／应用服务边界使用计数替身，不等于完整 App 窗口或物理设备验收。
旧剪辑导航 **317/0**、静音开片 **363 项**、真实 libmpv 剪辑导航 **28 项**通过。

补充生产 PlayerCore 方法抽取验证：

- `Tools/NativePlayerRouteTests/run.sh` **35/0**：真实 decoder/session/output/surface/VideoView、
  实际显示像素和状态 setter；首开自动播放、暂停首帧、静音、快速换片、停止及退出。
  MainWindow nib／周边服务和 MPV 是边界替身。只移除自动 resume 的负对照为 **33/2**。
- `Tools/NativePlayerCoreTests/run.py` ASan/TSan 各 **25 项**：受控异步 session 的
  shutdown/stop 优先级、回退途中开新文件、整批多文件等退场后重放与取消；不伪装为像素测试。
- `Tools/PlaybackMenuRoutingTests/run.py` AppKit **9 项**及 **22 个**菜单前置路由检查：
  回退完成前不发旧内核命令，菜单重建不篡改已请求动作，连续速度／音量取接受中的状态。

这些测试实际抓到并修复了退出 completion 被后续关窗覆盖、stopping→shuttingDown 非法跳转、
回退期间新开 B 却恢复旧 A、整批文件过早 append 到闲置 MPV 的问题。没有放宽状态或像素断言。

首个提交 `2884a403` 的 CI 完整 App 构建通过；新测试步骤因写死本机 Homebrew FFmpeg
路径而失败（运行 `38279550088`），并非整条流水线成功。后续步骤已改用构建产出的固定
`deps/executable/ffmpeg`，主窗口接入的新提交仍须独立通过完整构建／测试。
可通过手动 workflow 的 `upload_development_build` 取短期开发构建用于隔离验收；
这不会创建 Release、更新 appcast 或替换已安装 App。开发构建不得当成稳定更新交付。

后续接入复核补修：同一主窗口换视频时主动更新系统 Now Playing 标题／时长，native 标题
不查询闲置 MPV；播放／暂停的置顶偏好按状态变化更新。尚未迁移的 EOF 自动关窗配置明确
回退兼容路径。真实 route 回归增至 **46/0**；仅移除标题刷新一行的负对照准确触发两项失败。
拖入外部字幕／LUT 也必须先完成兼容切换，异步动作只持有提前复制的文件路径，不持有拖放对象。

第二轮 CI `38287243954` 的媒体 job 在旧窗口尺寸测试的抽取边界处编译失败：缺少新增 native
路由字段，不是生产视频像素失败。后续已补旧测试的明确 legacy 边界；不修改原有断言，也不将
这轮 CI 说成成功。该轮 build job 也确认在 Xcode App 编译前失败，具体证据与补测结果见下文。

三个 legacy 测试边界补齐后的本机结果：WindowSizing **70**、VideoViewport 两语言各
**1098**、HDRPreference **42**、HDRColorState **149**、PlaybackMode **126 + 6**、
PlaybackModeUI 三语言各 **51**，原 VideoTools 三语言各 **942 + 132** 与 ClipPreviewNavigation
**317** 均通过。拖放回归 **104/0**（ASan），移除新增路由的负对照按预期失败；这些不能替代完整 CI。

同轮 CI `38287243954` 的 build job 随后确认也在旧 PlaybackModeLive 抽取边界编译失败，
发生于 Xcode App 编译前；缺少 native 路由占位和带代次的 MPV hook 查询，并非该轮 App 已构建成功。
失败输出保留在 `build/native-ci-38287243954-{media,build}-failure.log`。
后续运行 `38289716396` 在依赖构建阶段主动取消，避免重复已知失败，不计为通过。
已为 PlaybackModeLive 补明确 MPV 分支的不可达 native 边界，不修改原断言。本机补跑结果：

- PlaybackModeLive：真实 libmpv **58**；PlaybackLifecycle live filter：ASan **18**。
- SilentVideoOpen：真实 libmpv + ASan **363**；ClipPreviewLive 全部案例 **324/0**，
  实际渲染 **309 帧**，自有临时测试 App 已清理。
- ScreenshotPreference：**147**；PlaylistPlayback：策略 **3854**、真实 libmpv **51**。
- MediaInfo：本地化 **156 键**，视频 **115**、图片 **175**、loader **15 + 6 个负对照**、
  routing **14**、窗口三语言各 **83**。
- VideoViewport Live 的独立边界仅补 `isUsingNativePlayback = false`，原实像素回归
  普通与 drop-redraw 恢复各 **149 项／54 帧**；ThumbnailDecoder ASan **161**；PlayerClose
  生产源码 typecheck 和两组辅助检查 **11 + 16** 均通过。
- 原 legacy 4K soak **180 秒通过**：6 次载入、3 次换片、15 次 seek、9 次速度变更，
  稳态 RSS 增长 **32.8 MiB**、footprint 变化 **−297.5 MiB**。本次是 4K 源解码后输出
  640×360 的软件渲染验证，`software_verified=1`、`hardware_verified=0`，
  不代表 native 后端长期稳定性、M4 AV1 硬解或 4K 屏幕输出验收。

本机旧依赖限制保留为失败证据：原 PlaybackRotation 首例 `unload / eof` 在 libmpv
`loadfile.c:1922` 的 `mpctx->stop_play` 断言退出 **134**，未放宽断言或标记通过；输出见
`build/native-ci-local-rotation-failure.log`。本机 `deps/playback-build-record/patches.tsv`
只有两项 ICC 补丁，缺少源码清单五项中的 `mpv-unload-seek-state` 等补丁；实际本机
libmpv SHA-256 为 `5a76b8188eecf781a22567f6902f67e8da82da99495e633da1aa2d3edd65e81e`。
该运行不能代表 CI 新构建的依赖，也不能将上述 fixture 通过等同于全部媒体测试通过。
本轮未替换本机依赖；完整新 App 编译与受限 native 主窗口验收仍待新的完整 CI。

新增 `Tools/NativeAppTests` 完整 App 测试构建，用编译条件 `CHENGYING_NATIVE_APP_TESTS`
启用专门驱动；正常 Release 中驱动与 AppDelegate 两处调用均不编译。测试构建在编译前使用
唯一测试 bundle ID 和独立 DerivedData，产物由 `TestAppWorkspace` 托管，只允许 disposable
GitHub-hosted macOS runner 运行；不修改正式配置文件、已签名包身份或本机已安装 App。
真实 PlayerCore、MainWindow nib、控件、renderer、MPV 均不替换为 mock，覆盖 18 个固定阶段，
结果需完整集合、每项通过、实际 App 退出 0 和隔离目录清理成功。编译边界 typecheck、生成
H.264 B 帧素材的色块／字幕验证只算准备验证，**尚不代表完整 App 18 项已通过**。

完整 App 测试后来加严：marker 保存 FFmpeg 独立解码的九点 YUV 参考，真实 displayed buffer
必须是 160×96 NV12，九点三个分量均在一个码值内，而非只检查左上角色度。runner 在超时／
非零退出时也在清理前保留合法、限大小、run ID 一致的固定结果文件；不接受部分报告为通过。
准备回归 **12 项**，包含实际生产比较函数的 **65 项**像素正反对照；声明边界与普通 Release
排除驱动的 typecheck 通过。这些仍不能代替实际完整 App 执行。

第三轮 `38292407187`（`c0469d5e`）的媒体 job 已通过此前失败的 native controls 步骤，
随后旧 ChromeLifecycle fixture 因缺少侧栏新路由接口编译失败。仅补五行明确 legacy 边界，
原四组 Chrome 检查 **632／40／185 + 4／865** 本机全过；后续相关抽取测试复核包括
RenderLifecycle **48 + 3855**、WindowLifecycle **188**、ThumbnailLifecycle **32**、
PlaybackLifecycle **76**、SeekTiming **37** 和原字幕匹配／列表／缓存检查，未改原断言。
失败日志保留于 `build/native-ci-38292407187-media-failure.log`。该轮完整生产 App 编译及
native decoder／output／session／surface／transport／主窗口方法路由回归均通过，随后
独立的测试驱动 App 编译失败：`displayedPixelBuffer()` 需要 macOS 14.4，驱动却仅做 14.0
检查。部署目标是 macOS 12；本机显式指定该目标可复现同一错误。失败发生于实窗运行前，
不能将生产 App 编译成功写为完整 App 的 18 阶段验收通过。日志及测试 artifact 保留于
`build/native-ci-38292407187-build-failure.log`、`build/native-app-ci-38292407187.M046Zz/`。
后续仅将驱动的 availability guard 改为 14.4；新增显式 macOS 12 deployment-target
正向 typecheck、普通 Release 排除驱动检查及精确旧 guard 的失败负对照。准备检查增至
**13 项**（仍含 65 项像素比较）；本机通过，不替代待运行的完整实窗验证。

按 SDK 合约复核又修正两项测试假设：`copyDisplayedPixelBuffer` 只保证零速率时可读，
因此自动播放改由两次真实 worker 共享时钟采样证明推进，再通过真实暂停菜单、确认零速率
后检查红色九点像素；第二 core 先暂停验蓝，再经真实恢复菜单和时钟检查后退出。
固定实窗验收增至 **23 项**，不是删除图像或自动播放断言。音量 70 经 Float 音频输出
再转 Double 会有约 0.0000012 的误差，只将测试比较改为 0.0001 内，含错误值／NaN 负例。
准备验证 **14 项**、实际像素与音量比较 **73 项**、macOS 12 编译及旧 guard 负对照通过；
完整 App 仍待运行。旧 `0c1ea242` 流水线 `38294430271` 被后续同分支运行的 concurrency
策略取消，不能计为成功；已提交 guard 修补的 `38296853923` 仍在运行，不含后两项测试修正。

隔离范围是唯一 player bundle 域和 disposable CI 主机，不是完整 HOME 沙箱。
当前固定测试不打开下载／字幕／AI 面板，也不启动其固定路径的数据服务；以后若扩展这些
步骤，须先补数据路径隔离，不能仅依赖更换测试 bundle ID。

线程边界复核另修一项旧 Now Playing 竞态：Quick Look 重试预算以前在 artwork worker
递增、主线程换片时归零，失效 worker 可能消耗新媒体预算。现先回主线程验证 ticket，
再检查／预留三次上限；封面优先级与 OSC 回退不变。`Tools/NowPlayingArtworkTests/run.py`
抽取实际协调方法，普通／ASan／TSan 各 **53 项**，含 1,000 次换片；精确旧方法负对照
稳定触发失效任务预算断言。系统封面生成与发布接口是受控边界，不是系统 Now Playing 实窗验收。

## 原生 A/B 主窗口接入（本地验证通过，完整 App 待运行）

`PlayerCore` 现在对 `[]` 与菜单 A→B→清除串行提交原生动作，从 session worker 精确采点，
不以周期 UI 缓存或正在闲置的 mpv 为时钟。A=0 与未设置分开表示；B 必须大于 A。
新开片、关闭和显式 seek 取消旧采点；明确修改标记也取消旧队列，取消结果异步通知，
避免回调重入 open／stop 事务。等待 preroll 的采点最多两秒，最多排队 64 项。
单文件循环偏好独立于 A/B；原生 seek 和 pending target 共用同一精确区间约束。

主窗口显示真实可选标记；无效拖动会还原显示并提示，不再发出成功的 OSD。
兼容切换先读取原生精确位置，再恢复可选 A/B 和原播放状态。已载入媒体临时 preroll
不再错误恢复到 0 秒；等待上限后保留原生路径并报错。初始不支持格式仍可回退，
已载入后的不支持格式变化明确停止，不能宣称中途格式变化已实现无缝恢复。

本轮最终局部结果：

- `bash Tools/NativeABLoopTests/run.sh` 与 TSan 各 132 项；真实 production session、
  受控 PlayerCore 边界，不是完整 MainWindow/nib 操作。
- `bash Tools/PlaybackTransportTests/run.sh` 与 TSan 各 132 项；session 209 项。
- `python3 -B Tools/NativePlayerCoreTests/run.py --sanitize address`／`--sanitize thread`
  各 37 项；终止优先级、准备中位置恢复、取消失效、取消回调重入四类负对照均按预期失败。
  负对照原始失败不是通过结果，也没有改掉保护断言。
- 旧路径回归：NativePlayerRoute 46、PlaybackModeLive 58、VideoViewport 两语言各 1098、
  VideoTools 三语言各 942 UI／132 task、ClipPreviewLive 324、SeekTiming 37 policy／38 live。
  SeekTiming 使用 `vo=null`，不是画面验收；最后一次 ClipPreviewLive 实际渲染 306 帧。
  旧 fixture 仅补本轮增加的方法／依赖边界，未降低原断言。
- 完整 App driver 保留原有 23 项并增至 41 项（含真实 `[]`、A/B 菜单、标记通知、
  无效拖动回滚、paused 像素与精确时钟）；准备检查 17 项、比较器 73 项及 macOS 12
  warnings-as-errors 编译通过。**41 项实窗测试尚未执行完成，不计为验收通过。**

此前仅含 API guard 修正的 `ceeaa21b` CI `38296853923` 的媒体 job 已通过；生产 App 和
测试 App 都完成编译，实窗前七项通过，随后 `real_volume_slider_action` 失败，整个 build job
失败。该版本不含 `3a01dfbf` 的 clock／pixel 修正和 Float 音量比较修正，也不含本轮 A/B，
不能代替最新版本验收。证据已下载至本机 `build/native-app-ci-38296853923.45IHOL/`，
旧 runner 将失败后的 cleanup 统一记为 unconfirmed，不能据此报告清理成功。新的 runner
分别记录 owned workspace 的实际 cleaned 状态与 App 失败，清理成功也不得抹去测试失败。

一项保留旧图以减少 loop flush 闪烁的实验已撤回：候选实测出现旧图残留，未纳入生产或
CI，仍保留原 `flush(removeImage: true)`。失败证据留在本机 ignored
`build/native-loop-rejected.RJ1Wpj/`；不以读帧 API 的短暂空值直接推断实体屏幕黑闪。
另已独立复现首视频延迟 1 秒、音频从 0 开始的 paused-open 阻塞：两种合成编码均先接受
47 个音频样本、视频为 0、音频背压、时钟为 0；恢复播放后可继续。普通同步素材通过。
真实 App 当前先 paused-open，因此这是待修复的准入缺陷，不只是测例限制。

## 延迟首帧、早期 seek 与暂停意图修补（最终验证中）

在两种合成容器独立复现：初次完整解码各有 188 个音频样本，从 0 开始；先 seek 到 2 秒
再 seek 到 0，旧 indexed seek 在 MKV 只留下 141 个、首 PTS 1.003，在 MP4 只留下
142 个、首 PTS 0.981333。这是解码器丢失原点音频，不是窗口等待或 FIFO 计数误差。
当前实现对原点、已知首视频之前的目标和未知首视频时间采用同一已打开 regular-file FD
重建解复用与解码，不重新打开路径；在串行 worker 先退出旧上下文，再 rewind 该 FD 副本。
保留 normalized origin 和能力摘要、取消状态及错误，原输入路径被替换不改变已打开身份。
普通后段仍走索引定位；原点循环会付出重建成本，不能据此声称性能更优。

session 为寻找首视频时被音频背压阻挡的样本提供有界 FIFO，保持原始 PTS 和顺序；
在恢复播放后先排 FIFO 再解新样本，包括同一轮 preroll 转 playing 和 demux EOF。
stop/open/seek/fail 都清理旧 FIFO，FIFO 转入 renderer 不重复计费。限制为 256 块、
8 MiB、相对目标三秒音频 lead，并与已提交输出共用 128 MiB；另有最多一个 128 MiB
decoder pending sample。**不是整个进程内存上限，也不支持任意长音视频间隔**。
超出限制明确失败，不偷偷推进暂停时钟、重排时间戳或丢音频以腾空间。

自动 A/B 回绕的 `.seeking` 不再等于用户暂停：snapshot 发布 worker 的 `wantsPlayback`，
transport 使用真实意图；idle/closed/failed 仍暂停，EOF 时已有 accepted pause/resume
意图优先，避免同一轮两次空格都被当作 resume。菜单无效 A/B 和采点暂不可用补明确提示。
准备阶段局部测试为 A/B 普通／TSan 各 151、transport 各 145，旧 phase-only 单变量
负对照准确重现空格不暂停。解码器重建后的同源码最终回归另行核实，不混算先前结果。

完整 App 驱动目前共 **47 项**：保留原 41 项，增加首视频延迟 1.5 秒而音频从 0 开始的
合成文件、真实 paused 时钟 0 像素、静止时钟、真实菜单恢复与时钟前进。准备测试
**21 项**、实际比较器 **73 项**、macOS 12 编译与旧 availability guard 负对照通过。
其中三项新增测试分别检查 App 失败但清理成功、App 与清理同时失败、隔离目录创建失败；
结果标记严格区分，不能把清理成功当播放验收通过。47 项真实 App 尚待最新候选 CI。

早期 seek 修补的普通、ASan、TSan 各通过原 9,265 项、新增 26,210 项以及 Swift EOF
308 样本检查；旧 indexed 行为负对照精确失败于 PCM 字节／PTS／duration 完整性。
证据见 `build/native-decoder-tests.rFeaYO/results.log`（TSan）、
`build/native-decoder-tests.VQwgjd/results.log`（预期失败）。同 FD 不等于文件内容不可变：
能力摘要不是整个文件哈希，不承诺外部进程原地修改字节时仍保持原内容。

冻结 session `5542c2670f188ff5c89a5d2d3f07b9937360057834db347ed7b765a32ddea3d1`
在原 session 套件 **209/0**（`build/native-playback-session-tests.mEhXLd/`），
自然输出定向套件 **117/0**（`build/native-preroll-audio-tests.U0Ltvz/`）。另以自有测试副本
把每次真实 video flush 的完成确认延后 300 ms，并保留实际 flush、计数和 DispatchGroup，
13 次重叠 flush 的正向 **126/0**（`build/native-preroll-audio-tests.SXtDoI/`）。只撤销
session 的 pending-flush 准入和 preroll FIFO 排序保护，**110 通过／16 预期失败**，
即使样本总数仍为 188/188，逐样本时间戳顺序检查仍能抓到乱序
（`build/native-preroll-audio-tests.UCXBbm/`）。这不是平台自然需要 300 ms 的结论。
以上定向素材的 x264 lossless 设置实际禁用了 B 帧；不能把这些结果称为强重排 B 帧验收。
后续 fixture 将明确验证 B 帧并重新运行，最终 sanitizer／4K 结果另记，不挪用旧十分钟结果。

同一冻结生产源码的最终串行结果保存于 `build/native-final-regression.zF0iHi/`：
NativeABLoop 普通／TSan 各 **151/0**，PlaybackTransport 普通／TSan 各 **145/0**，
ControlledCore ASan／TSan 各 **37 项通过**，六组退出 0、没有 sanitizer 诊断。
phase-only 负对照为 **147/4、退出 1**，准确复现 A/B 回绕时空格不能暂停。
前后输入 SHA-256 清单完全相同；旧 `6wlOQX` 是中间版本，不作为最终证据。
这些是命令行生产方法／核心回归，不等于完整 App、实体音视频设备或 M4 验收。

提交 `10d59252` 已推送开发分支并启动 CI
[`38305625981`](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/38305625981)，
不是标签发行。新的 H.264 定向 fixture 使用 CRF 18／固定 B 帧策略，并由 FFprobe 检查
实际解码帧（普通和延迟素材各 75 个 B 帧），不再以编码参数当作重排证据。自然输出
**117/0**（`5NkBbm`）、受控 flush 完成确认延迟 **126/0**（`3uNCAJ`）；相同 fixture 的
flush 保护负对照 **110/16**（`LHIaR7`），去除 FIFO 单条件负对照 **72/5**（`aNcN3L`），
后两组退出 1，不能标为生产失败或正向通过。前缀均为 `build/native-preroll-audio-tests.`。

**新 fixture 的本机 TSan 未全过**：`build/native-preroll-audio-tests.twnu4i/results.log`
为 116 通过／1 失败。FFV1/PCM 的 lifecycle paused seek 到 2 秒后，三秒内实际 renderer
图像仍为空，时钟为 2、rate 为 0、held 为 0；没有 TSan race 诊断，其他样本顺序检查通过。
此时不能把原因归为 B 帧、系统负载或物理屏幕黑屏；也不能只引用先前 TSan 通过掩盖它。
保留原断言和生产源码，正在用隔离观测副本进一步定位。随后两次相同输入的有界 TSan
运行 `jfzWen`、`UoFHbK` 各 117/0，仍不取消该失败。孤立 open→seek 的 12 次诊断成功，
没有完整前序生命周期且同步日志改变时序，不据此判为已修复。

随后一次完整原前序的隔离诊断 `build/native-preroll-ring-diagnosis.7te25h/` 保持原始素材与
三秒像素截止时间，TSan **117/0**；有界 ring 为 804 项、丢弃为零，只在末尾输出。
seek 到 2 的首个实际读回是 `raw nil`，约 14.3 ms 后是正确 NV12；两时钟均为 2、rate 0，
flush 完成、renderer 无错误且 `isReadyForDisplay=true`。这只能证明该次短暂空值存在，
没有复现原三秒失败；不能据此把 ready 标志或追加帧当作生产修补，也未继续重复碰运气。

上述开发 CI `38305625981` 最终失败：媒体 job、完整生产 App 编译、decoder 全部检查、
output 96、display 36、普通 session **209/0**、实际像素 **66/0** 通过；随后 session
TSan 为 **208/1**，唯一失败是 `[0.5,0.9]`、速率 1.2 的 A/B 在固定 1.5 秒内只有一次
已提交视频时间戳回绕（65 samples、phase seeking），未达到至少两次。没有 TSan race 报告；
尚不能判为永久卡住、生产退化或单纯测试时间窗错误，不改期限、不抹去失败。
日志保留 `build/native-ci-38305625981-build-failure.log`。本轮没有跑到完整 App 47 项。
后续手动开发 CI 仅在生产 App 已编译且未取消时继续采集各独立 native 套件和实窗证据；
失败仍使 job 失败，打包与发布的成功门禁不变，没有 `continue-on-error`。

新生产源码的默认三分钟 4K 重跑已完成：`build/native-playback-soak.Q9odqV/`，
**292/0，182.45 秒**，九项输入文件 SHA-256 前后一致。实际读回 3840×2160 NV12／P010，
三个 session 的 weak 引用均释放，损坏格式和未知颜色均为零；三轮空图读回次数为 5／4／2，
不将其直接解释为实体屏幕黑帧。应用队列记账峰值 124,606,976 字节、进程 RSS 峰值
260,882,432、footprint 峰值 200,868,944 字节，仅是本次采样，不是总内存保证、零泄漏
或相对 MPV／Movist 的性能优势。旧十分钟结果仍属于旧源码，不能混为此次十分钟验证。

## 原生画面缩放／平移（完整 App 验收待运行）

原 `=/-`、⌘⇧方向键和 ⌘⇧0 现直接调用 native surface，不为这些动作退回 MPV。
沿用现有 0.2–8 倍、每次 0.1 倍与边界限制；normalized pan 使用旋转后、SAR 修正后
缩放图像的宽高，正 Y 向下只在 surface 转为 AppKit 坐标时反号。每次 resize 重新计算
点偏移；原 point-based API 保持不变。新媒体同时清模型与显示层状态，关闭／退场拒绝修改。
同媒体兼容切换先捕获最后接受的 viewport，在 MPV 正常开片复位后、恢复 seek 前写回。

最终生产输入 SHA-256 前后一致，证据保存于 `build/native-viewport-regression.LKPhUf/`：

- `bash Tools/NativeViewportTests/run.sh` 普通、ASan、TSan 各 **172/0**；包括四向旋转、
  非方形像素、宽／窄窗口、非零 bounds、零尺寸恢复、键盘路由、文本输入隔离及停止屏障。
  首轮未启动 NSApplication 生命周期而无法成为 key window 的失败保留；修正测试生命周期，
  原断言不变。Y 方向与 compatibility 分派两个单变量负对照分别 **63/109、165/7**，退出 1。
- 真实 session／VideoView route **48/0**，VideoView **34/0**，原 Surface **106/0**；
  受控异步 Core ASan／TSan 各 **41/0**。不以边界替身当成完整 App。
- 旧 viewport 两语言各 **1098/0**；真实 libmpv 恢复 helper **164 项／61 帧**，
  VideoTools 三语言各 **942 UI + 132 task**、Rotation **77**、A/B **151/0**。
  ClipPreviewLive **324/0、309 帧**，自有临时测试 App 清理成功。
- 完整 App driver 保留原 47 项并增加 13 项 viewport 键盘、几何、resize、复位与暂停时钟，
  共 **60 项**。准备测试 **23**、实际像素／音量比较器 **73**、独立图层几何比较器 **46**，
  macOS 12 typecheck 和旧 guard 负对照通过；**完整 60 项尚未实跑通过**。

`displayedPixelBuffer` 是变换前源像素，不能证明最终屏幕平移；新 driver 分开检查源像素与
实际挂载 layer 的几何。SAR／旋转有独立几何验证，但完整 App 新步骤只用 SAR 1／旋转 0；
没有旋转／SAR＋全屏组合或 native→MPV 同时关窗的完整实窗验收。默认路由和发布配置未改。

## 实现文件

- `iina/NativePlayback/CYNMediaDecoder.{h,m}`：只读本地文件、FFmpeg 收帧／drain、
  VideoToolbox CVPixelBuffer 路径、8/10-bit 420 软件路径、浮点 PCM、seek、终止式取消。
- `NativeSampleBufferOutput.swift`：音视频共享时钟、真实音量／rate 读回、背压、flush、
  异步 renderer 拆除。默认音量为零，不修改系统音量。
- `NativePlaybackSampleGate.swift`：半开 A/B 区间、PCM 逐样本裁剪、视频边缘时间裁剪、
  有理数样本结束时间，避免长时间线浮点误差。
- `NativePlaybackSession.swift`：独占 worker、媒体和 seek 双层代次、旧帧／旧回调失效、
  暂停／恢复、0.5–2.0 倍速、seek、单文件和 A/B 循环、每次开片静音、EOF、停止与关闭。
- `iina.xcodeproj/project.pbxproj` / `iina-Bridging-Header.h`：真实工程引用及系统 frameworks。
- `.github/workflows/ci.yml`：在完整 App 构建后运行新后端五组回归及 session TSan；
  未增加发布捷径。

所有 FFmpeg 操作和 renderer 队列操作位于同一串行 worker，主线程只发命令、收快照和挂图层。
取消使用原子标记；不把阻塞式文件读取移到主线程。普通网络文件系统即使设置 `O_NONBLOCK`
也不保证马上返回，因此不承诺任意存储的取消都在固定时间内完成。

输出队列的应用侧记账预算为 128 MiB，另有一个 pending sample；**这不是总进程内存上限**，
也不包含 FFmpeg、VideoToolbox 和系统 renderer 的内部缓存。显示层不是一个无限增长的应用帧数组。

## 已确认的测试与修补

测试只生成合成媒体，不读用户文稿、私人媒体、浏览器、Cookie 或钥匙串。均为 CLI；
真实显示测试只创建自己的 NSWindow，无 `.app`、桌面截图、录屏权限或 LaunchServices 注册。

| 命令 | 本机结果与边界 |
| --- | --- |
| `bash Tools/NativeDecoderTests/run.sh` | Objective-C 9265 项与 Swift optional EOF／seek／cancel 通过；H.264、HEVC PQ 10-bit、FFV1 8/10-bit、非零起始时间、旋转元数据、六声道、24/32-bit 精度边界、原始格式与硬件输出一致性、HDR 精确字节及非法元数据拒绝等。 |
| 最新 decoder 源码 ASan + UBSan / `-Werror` | 9265 项通过，无 sanitizer 报错；这不是整个 App 的 sanitizer 验收。 |
| `bash Tools/NativeSampleBufferOutputTests/run.sh` | 96 项通过，包括实际共享时钟、rate／anchor、队列背压、现代 renderer 身份、关闭释放以及错误队列调用的负对照。 |
| `bash Tools/NativeSampleBufferDisplayTests/run.sh` | 36 项通过；读取生产 renderer 的实际 displayed pixel buffer 九点颜色，验证红→绿、暂停不显示后续蓝帧、flush、前后跳转、13 次重叠异步 flush 和关闭清图。不等于实体屏幕 HDR 色彩或可听音频验收。 |
| `bash Tools/NativePlaybackRenderedTests/run.sh` | 66 项通过，连续多轮通过；合成媒体经独立 FFmpeg 原始字节校验，再走生产 decoder → session → renderer，读回真实 NV12 像素。包括 H.264 B 帧暂停双向 seek、8 次快速换片、停止后重开及异步关闭。 |
| `bash Tools/NativePlaybackSessionTests/run.sh` | 209 项通过，包括音轨时长不等、EOF 重播、极短 A/B、自动音频 flush 回调注入和恢复次数上限、跨文件偏好及暂停 H.264 首帧。验证真实 decoder + output + session，不是 mock 播放时钟。 |
| `NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativePlaybackSessionTests/run.sh` | 同样 209 项通过、退出 0、无 TSan 告警；实际链接 TSan runtime 且 decoder.o 含插桩。预编译 FFmpeg 和 Apple frameworks 未重新插桩，不是第三方内部完全无 race 的证明。 |
| Swift typecheck / `plutil -lint` / `git diff --check` | 通过。完整 App Xcode 构建尚待 CI，本机只有 CommandLineTools。 |

本机原始证据保留于 ignored `build/`，没有提交测试视频和日志：

- decoder：`native-decoder-tests.2ras0M`；sanitizers：
  `native-decoder-tests.GvL5ls/decoder-sanitizers-final`。
- session：`native-playback-session-tests.SFDY77/results.log`（209 项），
  TSan：`native-playback-session-tests.syTS8u/results.log`（209 项）。
- 完整画面链路：`native-playback-rendered-tests.hsvQza/results.log`（66 项）。
- 初始 session 45/3 失败保留在 `MAvUhj`，修补后 `zfBNtr` 的原 48 项通过。
- 不等长音轨首轮 `oNem4x` 为 88/2 失败，修补后 `4dZZmy` 为 95/0。
- `5zv0MT` 的 108 项增加 EOF 重播及 30 秒视频／1 秒音轨的 `[2,3]` 回绕。
- 极短 A/B 首轮 `V0H6CJ` 为 122/2：三秒收集不到二十轮，不是越界或停止失败。
  保留二十轮实际执行、样本区间和停止不超过 0.5 秒的断言，将收集期限改为十秒，
  不宣称任意机器在三秒内能完成二十轮。随后 `OaxZUb` 完成二十轮，停止约 11.1 ms。
- H.264 暂停跳到 1.7 秒的真实画面首轮为 65/1：session 已 paused，但没有首个视频样本，
  实际显示为空。最初怀疑旧时钟；单独加锚点屏障仍为 65/1，因此没有把这一推测当成结论。
  严格负对照 `native-playback-rendered-tests.hoGToh` 只移除暂停等首帧条件，仍为 65/1；
  同一现代 output、素材和像素断言下，修补后为 66/0，1.7 秒实际 NV12 为 `[173,42,26]`。

本阶段已修补：

1. 9000 秒／192 kHz PCM 的浮点相减多裁一个样本；改用绝对样本坐标及有界 ULP。
2. 连续 `setLoop → seek` 把较早 loop 命令当成旧 seek 丢弃；控制命令按媒体代次保序。
3. 短音轨或延迟音轨导致双轨 preroll 无限等候；有界预缓冲后仍按原 PTS 播放，不挪音轨。
4. 短音轨的 A/B 等待全文件 EOF；B 改为时钟硬边界，入队仍逐样本截断。
5. EOF 冗余 pause 抹去 ended，下一次 resume 无法重播；保留 ended 语义。
6. 极短 A/B 的同步递归 `seek → pump → seek`；每次 seek 必须异步让出 worker。
7. AAC 尾部 padding、Double 样本结束时间比 duration 多 1 ULP 导致 EOF 永不完成；
   按媒体区间 gate 并使用 `CMTimeAdd` 计算可达结束点，不用宽松时间容差掩盖问题。
8. 开片／回跳时异步 timebase 锚点尚未生效；等待真实 rate 为零且锚点到位后启动。
9. 重复 shutdown 从 main 误调 output；重复请求仍进入 worker，完成回到 main。
10. FFmpeg 时间戳／seek origin 溢出、嵌套输入、完整 32-bit／64-bit 音频无损转
    Float32 不成立等边界；返回明确 unsupported，不静默降精度。
11. preroll 中自动音频 flush 曾被忽略；现在重新定位和重填两轨，并限制十秒内三次恢复。
    注入四次回调验证会明确失败并停止重试；这不是实际拔插声卡／耳机的验收。
12. 暂停 seek 不得仅因音频到达且等待超过 0.1 秒就结束 preroll；必须等到视频首帧或真正 EOF，
    否则暂停会停泵，B 帧尚未解码便留下空画面。未采用 DisplayImmediately 绕过共享时钟。
13. macOS 14+ 全部队列操作使用同一 video renderer；所有重叠异步 flush 完成前禁止入队，
    shutdown 等待 flush 与 renderer 拆除完成，迟到的 flush 不得抹去新帧。
14. 快速连续 open 之前设置的倍速和单文件循环按媒体代次保存；A/B 清空，音量始终归零。
    这是 session 实例内行为，不代表正式 App 的偏好或 UI 已完成迁移。

## 能力限制：默认切换之前必须处理

- 仅本地 regular 文件；不接收网络 URL、嵌套播放清单、目录或设备。
- 当前解码策略支持 8/10-bit 420、标准色彩标签和静态 HDR 元数据。动态 HDR、ICC、
  交错扫描、未知／镜像变换、软件非 420／大于 10-bit、不能无损表示的 PCM 明确拒绝。
  App 级兼容路由正在验证，不能仅据 decoder 的 unsupported 结果宣称完整 App 已回退成功。
- `videoToolboxDecoded` 证明 CVPixelBuffer / VideoToolbox 路径；`hardwareDecoded`
  仅在锁定 FFmpeg 路径明确要求硬件时为真。FFmpeg 7 的 HEVC 允许软件 fallback，
  因而 HEVC 的 false 是“实际硬件未确认”，不能标作软件解码或硬解失败。
- 本机不是 M4；AV1 M4 硬解、实体 HDR 屏、ICC 色彩、真实音频设备切换和可听音质未验收。
- 旋转、SAR 和画面缩放／平移已接入新 surface；完整 App 组合验收仍未完成。
  完整字幕／轨道选择、截图、帧进、HDR 用户开关、播放列表策略及剪辑预览恢复仍走兼容路径。
- 倍速当前只承诺 0.5–2.0；不能直接取代旧界面更广的速率范围而不给用户提示。
- 暂未测得相对旧内核／Movist 的耗电、CPU、总内存、丢帧或启动速度优势。

## 下一阶段接入清单

1. 已有 `PlayerCore` 开片、transport、音量、单文件循环、A/B 和异步关闭分派；继续完成
   完整 App 验收并解决暂停图像偶发不可读，不把独立 core 通过当成整窗成功。
2. 已隔离 `VideoView` 的 GL 假定并迁入图层几何与 viewport；继续验证全屏／跨屏／真实
   HDR 色彩，补已加载 native→MPV 的整窗状态交接，不直接放开现有准入保护。
3. 快捷键已迁入速度、A/B、viewport；其余旧 mpv 透传仍明确兼容，继续补齐截图、帧进、
   音轨等能力。日常同文件夹多媒体／播放列表及已用 MPV core 的 native 再进入仍待设计验证。
4. 改造 `VideoToolsPlayerBridge`、预览 snapshot/restore/onUnload；重复编辑 A/B、
   切片预览、快速换片和关闭必须用真实窗口／实际画面回归。
5. 明确支持矩阵、功能补齐及兼容选择，保留已有音视频品质和每文件音量零策略。
6. 完整 App 构建、真实窗口回归、目标 M4 验收通过后，才切默认路径并进行原有签名／
   增量更新／公开交付发行流程。当前不是发布候选，不给未验收换核包打稳定标签。

## 2026-10-13 新内核 4K 独立压力验证（非完整 App 验收）

新增 `Tools/NativePlaybackSoakTests/`，只包含 tracked 测试、Mach 内存采样辅助和说明。
未修改生产路径、默认后端或 CI workflow。生成本地 H.264/AAC 8-bit 与 HEVC Main10/AAC
10-bit 合成素材，实际经过生产 decoder → session → output → surface，创建自己的
640×360 CLI AppKit 窗口，不生成／安装 `.app`，不读取用户媒体，不截取桌面。

读回的是生产 renderer 的实际 `displayedPixelBuffer()`：必须为 **3840×2160**，H.264
保持 NV12 8-bit，HEVC 保持 P010 10-bit；不是只检查源文件的 4K 标签。独立 FFmpeg
解码建立四个源区间的 YUV 参考；每次暂停 seek 比较九个位置的像素（允许一个码值差），
要求实际共享时钟 rate 为零且位置距目标不超过 1 ms。每次 seek 还验证实际接受的
audio/video sample 计数都增加，日志保留 refill 增量、声道数／采样率与实际 clock/rate。
接受音频样本不等于可听音频或 A/V drift 验收，素材和输出始终静音。

测试版本与证据不得混淆：

- 最初 `NATIVE_SOAK_SECONDS=60 bash Tools/NativePlaybackSoakTests/run.sh`：
  250 项／0 失败，62.49 秒，`build/native-playback-soak.muCH1S/results.log`。
  当时持续段只检查至少四种不同像素 signature。
- 加入 seek 双轨 refill 断言后的初版 180 秒：289 项／0 失败，182.44 秒，
  `build/native-playback-soak.dlW2pC/results.log`。仍不是最终持续像素断言版本。
- 只读 review 指出“变化过四种”不能证明颜色正确，因此最终版改为每次非空读回
  必须匹配独立源参考、最终 phase 集合恰为 `{0,1,2,3}`；未知颜色单独失败。
  冻结版 `bash Tools/NativePlaybackSoakTests/run.sh`：**292 项／0 失败**，182.26 秒，
  三个独立 session 各运行约 60 秒，证据为 `build/native-playback-soak.WbPdz3/`。
- 最终版负对照：
  `NATIVE_SOAK_WRONG_REFERENCE=1 NATIVE_SOAK_SECONDS=60 bash Tools/NativePlaybackSoakTests/run.sh`。
  仅把期望参考改成下一个源区间；16 项中恰有首次像素比较失败，退出 1，正常完成
  异步关闭和释放，证据为 `build/native-playback-soak.oQJFvE/`。正负对照的
  `source-sha256.txt` 完全一致；不是换一套 mock 代码构造失败。

最终版涵盖 39 次显式 seek、36 次快速替换 open、0.5/1/1.75 三种实际时钟速率、
stop 清图后重开与三个独立关闭周期。**三次关闭后 weak session 引用都已归零**。
三轮持续段均读到四个正确源区间，损坏尺寸／格式和未知颜色都为零；含启动／循环 flush
的持续段无图像观察次数为 **2／0／2**。未单独测量每次空图持续时间和原因，已如实保留，
不能声称无缝循环或完全没有卡顿。
读回次数也不是唯一呈现帧数，不据此报告渲染 FPS。

应用侧已发布的在途 sample 记账峰值为 124,623,360 字节，未越过 128 MiB 预算。
每秒 Mach RSS／physical footprint 与 generation、revision、phase、queue 采样保留于日志；
本次进程峰值分别为 249,331,712／192,299,968 字节。第二到第三轮关闭后的差值分别
为 -51,593,216／-79,446,064 字节。这些只描述一次 M2 Pro 运行，**不是总内存保证、
零泄漏证明或相对 Movist／libmpv 的性能优势**；FFmpeg、VideoToolbox、IOSurface 与
系统 renderer 缓存不由应用 128 MiB 预算完全约束。

H.264 取得独立 hardware sample 证据；HEVC 仅确认 VideoToolbox 路径，不把允许软件
fallback 的 sample 宣称为硬解。均匀色块素材便于精确像素比对，不代表复杂电影、
数小时文件、M4 Max AV1、实体 HDR／EDR、真实声卡、完整主窗口操作或默认后端切换验收。

同一冻结源码追加十分钟验证：
`NATIVE_SOAK_SECONDS=600 bash Tools/NativePlaybackSoakTests/run.sh`，退出 0，
**292 项／0 失败，602.48 秒**；三轮分别约 200.15／200.14／200.11 秒。
证据为 `build/native-playback-soak.GKG7pu/results.log`；源码清单与最终 180 秒及负对照
完全一致，结束后逐项校验仍一致。三轮 phase 集合均为 `{0,1,2,3}`，损坏格式和未知颜色
均为零，无图像观察为 **4／1／1**；未测空图持续时间，不能说完全没有卡顿。
三次 weak session 均释放，队列记账峰值 124,623,360 字节；RSS／footprint 峰值
252,854,272／201,098,176 字节，第二至第三轮关闭后差值为 +4,128,768／−65,536 字节。
这些是该次进程采样，不是内存上限或零泄漏结论。测试没有修改默认路由、安装或注册 App。
