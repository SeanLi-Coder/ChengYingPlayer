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
- 旋转和 SAR 已在新 surface 测试应用，但没有完整字幕／轨道选择、截图、
  帧进、画面缩放平移、HDR 用户开关、播放列表策略及剪辑预览恢复。
- 倍速当前只承诺 0.5–2.0；不能直接取代旧界面更广的速率范围而不给用户提示。
- 暂未测得相对旧内核／Movist 的耗电、CPU、总内存、丢帧或启动速度优势。

## 下一阶段接入清单

1. 将 `PlayerCore` 的开片、transport、状态、音量、模式和异步关闭改成明确后端分派。
   `NativePlaybackSnapshot` 更新 `PlaybackInfo`；关闭仍可靠发出 `.iinaPlayerShutdown`。
2. 隔离 `VideoView` 和 `MainWindowController` 对 ViewLayer／OpenGL 的假定；分别实现
   native 图层尺寸、backing scale、全屏、旋转、色彩及关闭顺序。
3. 改造 `PlayerWindowController` 的原始 mpv 快捷键透传及读回，不得悄悄操作闲置 mpv。
4. 改造 `VideoToolsPlayerBridge`、预览 snapshot/restore/onUnload；重复编辑 A/B、
   切片预览、快速换片和关闭必须用真实窗口／实际画面回归。
5. 明确支持矩阵、功能补齐及兼容选择，保留已有音视频品质和每文件音量零策略。
6. 完整 App 构建、真实窗口回归、目标 M4 验收通过后，才切默认路径并进行原有签名／
   增量更新／公开交付发行流程。当前不是发布候选，不给未验收换核包打稳定标签。
