# 独立播放内核迁移：第一阶段

## 状态与范围

用户于 2026-10-12 明确要求实际替换播放内核。本阶段开始于当天，验证跨至
2026-10-13，工作分支为 `codex/native-playback-core`，基于 `ee83d00a`。

**换核尚未完成，不是已发布版本。** 新后端已加入 Xcode 编译工程，能独立解码、同步播放
音视频和呈现实际画面。`PlayerCore` 与主窗口正在接入严格受限的内部 native 路由；
正式默认及字幕仍使用 libmpv；内部 native 路由已接入剪辑预览。冻结 0455ab7c 的完整
App 92 项及队列 54 项已通过，但整条 CI 尚未通过，也未覆盖后续交接修补。
没有改变默认播放路径、版本号、用户偏好、已安装 App、更新源或签名身份。
不要仅因新文件进入编译工程，或下述测试通过，就宣布正式播放器已经换核。

实现路线是独立的 FFmpeg demux/decode → CoreMedia samples →
`AVSampleBufferVideoRenderer` / `AVSampleBufferAudioRenderer` → 共享
`AVSampleBufferRenderSynchronizer` 时钟。新后端不调用 mpv，也不是套用 AVPlayer。
macOS 14 及以后统一操作 display layer 的 `sampleBufferRenderer`，不混用两套队列 API；
较早系统保留 display layer 队列路径，当前仅通过部署目标编译，未做旧系统运行验收。
参考前一轮 REA 研究的高层职责划分；未复制 Movist Pro 的代码、反编译输出、二进制或资源。
不声称已经得到 Movist 的同一内核或性能。

### 2026-10-14 开片与精确定位响应切片

用户确认较大视频普遍有延迟，本轮使用合成素材检查，而非要求单个私人样本。
开片准入先取消旧目录扫描再等待列表锁；native preroll 去掉有进展时每批固定 10 ms
等待，并保留有界让出、真实背压等待和首 PCM 门禁。精确位置、画质与音频精度不变。
完整证据、历史失败与正在收尾的冻结矩阵见
[合作记录中的延迟修补](../AI_COLLABORATION.md#2026-10-14-开片与精确定位延迟修补待同源整窗验收)
和 [NativeSeekLatencyTests](../../Tools/NativeSeekLatencyTests/README.md)。
正式默认、发行与 M4 AV1 验收状态均未改变，不能把受控输出计时当作 Movist／完整 App 对照。
冻结提交 `211b2153efaee6a9f83d7fb830e3ccdcdc4e8f60` 已推送；开发 CI
`38430341318` 于 2026-10-13 16:25:13 UTC 派发且最近核实时仍在运行，App 上传关闭。
本地正向／负控和 AAC 已知失败分别保留，不能提前宣布完整 App 验收或发布完成。

### 当前整合检查点

2026-10-13 继续开发，新增首次 idle 队列门禁、忙操作保护和音频偏好路由修补。
以下是尚待新冻结 CI 的局部结果，不修改随后保留的旧 CI 失败状态。

- 安装器等待真实 `MPV_EVENT_IDLE`，原 deadline／owner／current-playing 卸载屏障不变。
  本地普通／ASan／TSan 各 253/0、八组精确负控；200 次八项列表取消 TSan 为 600/0。
  真实事件延迟确认测试不是把 MPV worker 固定在 prepare_playlist 之前，不能声称已经
  确定性重现旧 CI 的调度。锁定 MPV 0.38 的源码顺序支持该保守门禁；升级库必须重新核实。
- 静音、逐帧、截图入口此前在非 generic 交接、异步 inventory 和半建队列中可写 MPV
  或撤销旋转 owner。旧 Core `fbbc0af8` 的 `95G3mE` 为 353/52，保留真实命令／状态证据。
  Core `c0c69a4a` 加三处首行 gate；actions 三模式均 406/0，三个精确负控 11／18／29
  项失败，原附件 408/0。正常 native 与已恢复 MPV 都有可用性正对照；截图只验证生产
  准入前缀和计数服务边界，不声称截图文件／像素验证。
- 偏好设置设备选择此前仅改全局 UserDefaults，KVO 直接写闲置 MPV。现改主线程
  Core 路由、最新值合并、退出取消和真实 reader shutdown 门禁；一次 native 交接失败
  后不自动无限重试。此专项为真实 KVO／AppKit 控件与明确 Core 投递记录边界，实际
  Session／libmpv 设备交接由原 90 项专项另行验证，不证明物理声卡输出。
  最终 Controller `4af2e24d` 的真实 KVO 三模式各 31/0，五个精确负控为
  18／3／2／1／2 项失败，编译／完整标签／子进程／身份／sanitizer 门禁通过；根代理
  独立复核八份 source-before/after、生成 Swift 与二进制 SHA 及最终退出状态。
  同值 UserDefaults 写入实际不发 KVO，不承诺重新选同一个已保存设备立即重试；
  改选不同值或下次开片按保存偏好处理，实际限制和中途错误假设均保留在专项 README。
- 本轮普通 Generic 夹具 `nIIZs8` 在新增 gate 的 `hasPendingURLPlaylistEnqueue` 依赖处
  编译失败，未运行断言。已抽取真实单行 getter，派生 Audio 防重复，Subtitle 在替换
  真实 enqueue 块前撤掉重复 accessor；生产逻辑不因夹具改动改变。最终普通 Generic
  `w1GNPh` 218/0、Audio `IRkJEA` 90/0、Window `M6DV70` 208/0、附件 `m5ZzPw` 408/0；
  新共享清单下 actions 普通／ASan／TSan `JhkugU`／`5ByvNO`／`BiJGKC` 各 406/0，
  三精确负控 `FjdqZa`／`vCkxoH`／`KmclQL` 为 11／18／29 项准确失败、验证器 0。

续播切片正在实现，组件和真实播放接线正在验证，尚未整窗验收；设计与初始静态缺口另见
[续播保存与兼容恢复设计](2026-10-13-native-resume-design.md)。正式默认仍 MPV，
没有版本／发布／签名／更新源变更，不能因这批专项通过而宣布整体替换完成。

新冻结 `24b6666bcb3ad50721dd270b7e9fa151728c008d` 已推送；开发 CI
`38398139742` 于 2026-10-13 12:33:17 UTC 派发，已结束且失败，
`upload_development_build=false`。media-helper job 通过；生产 App 在
`iina/MPVController.swift:1460` 编译失败：`cannot find 'MPV_EVENT_IDLE' in scope`。
当前 95+54 整窗没有执行；正在核查生产头文件与独立夹具的 deprecated API 差异。
该失败不能由局部测试通过覆盖，也不改变版本或正式默认路径。
下段为上一轮完整保留的证据。

上一轮开发 CI `38381002473` 于 2026-10-13 10:05:47 UTC 派发，冻结
`0455ab7c7dc207e3bc46349eda1ea6c148c1b891`，已结束且整体失败。
`upload_development_build=false`；没有新发行或可交付 App 验收结论。
该冻结版本的生产 App 与隔离测试 App 均编译通过，实际 baseline 92/92、独立队列
54/54 全过，两进程 exit 0 且没有超时。五份 build/process identity-validation 均通过，
outer summary 确认清理完成、普通 App 不含测试驱动。原 nib／菜单／滑条、像素读回、
剪辑自动预览、静音开片、非默认状态真实两核交接及所有 Core 退出得到实际整窗验证。
队列还验证真实重复项身份、循环／导航、整表恢复、半安装关窗后重开。原报告在
`build/native-ci-38381002473-app.v4Pomn`，artifact ID `11804927964`。
media-helper job 因旧 PlaylistFilterTests 边界编译失败，后续局部修补不能改写该次失败。
随后两个独立队列／半安装取消 step 也失败。artifact `11808626559` 已保存到
`build/native-ci-38381002473-queue.pDioB2`：`jMKL1y` 安装器正向为 207 项中 1 项失败，
`tw1TEx` 重复取消为 600 项中 4 项失败，均为实际正常编译后的运行失败。
前者 activationFailed 的 cleanup 为 unverified；后者在 200 次实际取消中的四次未能
验证空闲空列表。快照中 idle 为 true、无 path／playing，但列表仍保留 current 项。
这是实际失败证据，不是负控；正在定位，不能用本地未复现覆盖它。
本次整窗通过不包含之后的窗口全屏／置顶和字幕／LUT 交接修补；仍须新冻结 CI。
本次包含以下较早失败之后的修补；不得把后续文档提交当成该 CI 的源码变更。

`f142f270` 的新整窗候选保留全部原 92 项及独立队列 54 项，再增加三项：实际置顶菜单
改变 NSWindow 而不提前写闲置 MPV，切核后真实窗口和 MPV 标志一致，并在稳定间隔后
再次检查。当前 baseline 为 95 项，原时限不变；主代理独立重跑 47 项准备检查通过，
尚未执行新冻结完整 App。该补测不模拟或证明 Spaces 全屏动画。

最新整窗候选保留原 92 项，新增独立进程的 54 项队列检查，不能互相替代。
两种开片暂停偏好、实际切换途中关窗并立即开片、替换后的 MPV 列表、静音、
渲染视图所有权及三个 Core 关闭均必须通过。44 项准备测试已过，包括 macOS 12
类型检查及实际像素／列表比较器；当时完整 App 执行待验证。冻结提交 `67dbc550`
的开发 CI `38356250711` 已结束且失败：media-helper job 在 HDRColorStateTests 旧边界
编译处失败，build job 在 ClipPreviewLiveTests 缺 `nativePreviewBaseline` 的旧边界
编译处失败。完整 App 编译与队列／bridge／整窗均未到达；日志证据在
`build/native-ci-38356250711.l5hmdB`，没有 workflow artifacts。后续明确无 native
边界修补通过本地颜色 149 项及剪辑预览 build-only，不冒充运行中的预览验收。
没有发行或开发 App 上传。下文保留的失败
`38337569102` 不被本次准备结果覆盖。

后续冻结 `35d992488d9872c0e18ee780f1c9dc90f34f6d9b` 已推送，开发 CI
`38361506765` 于 2026-10-13 07:15 UTC 派发，现已结束且失败；开发 App 上传仍关闭。
本地最终负控证据在派发后补入文档，不改变该次 CI 的冻结内容。

截至 07:52 UTC，该 CI 的生产 App 已编译通过，实际剪辑预览、4K 关窗重开与
持续播放回归通过，独立新内核检查仍在执行。media-helper job 已在旧
PlaybackLifecycle fixture 编译处失败：它未声明 generic owner／receipt 接口，
没有运行到对应行为断言。现已补明确 MPV-only、误入 native 即失败的边界，
Core `14d8d140` 下 Intel 10.15 typecheck／ASan lifecycle 76/0 与真实 libmpv
filters 18/0；修前失败及前后源码身份保留于
`build/playback-lifecycle-generic-boundary.DbK9r3`。不能把本地修补写成原 CI 成功。

### 后续窗口与附件交接修补（尚待新同源 App CI）

真实 loaded native→MPV 交接发现旧 MPV 的 fullscreen／ontop 属性仍是初始值，
`checkUnsyncedWindowOptions` 会退出全屏或降低窗口 level。现在只对已准入、已加载且
owner 仍有效的 native 恢复记录，在 renderer 退场完成后、MPV 开片前投影最新窗口状态；
普通 MPV 开片、未准入 fallback、取消／新媒体不继承该投影。旧源 `uYII5O` 为 24/14；
最终 Core SHA-256 前缀 `fbbc0af8` 的普通 `WXqznn`、ASan `Jxis2K`、TSan `UZ5JTr`
均 208/0，根代理独立普通 `1y8fVf` 亦 208/0。四精确负控 `3YdzqP`／`Rbxsiy`／
`cE2PyS`／`LG8wi8` 分别准确失败 34／40／3／1 项。前三正向清单与最终负控仅
非编译 validator 不同，生产／抽取器／测试断言未变；根代理最后普通与最终负控的
完整清单相同。旧 swap 控 `p7r9fv` 40 项失败被错误先验 44 项拒绝，原证据保留，
只修 validator 对已经进入全屏后不降低 window level 的预期；未弱化正向断言。
AppKit Spaces 动画和完整 MPVController 属性事件不是该专项的验收范围。

另发现字幕 drop 被 `openMediaURLs` 的提前 invalidation 当成新媒体，撤销正在退场的
generic owner；旧源真实重现 `PJXTe1` 17/6。只把 invalidation 移到有效视频输入之后，
并统一拒绝 capture／retire／load／seek／半建列表期间的字幕与 LUT 附件。真正新媒体
仍能取消旧动作。独立复核还发现单片异步 inventory 期间 transport 未建立而旧 MPV
路由已关闭，旧 gate 仍接受附件；`kuAD4p` 9/4 证实实际 sub-add／vf 写入闲置 MPV。
现以 transport 存在或 MPV 事件路由可用为附加必要条件，正常 native／MPV 附件不受影响。

最终 Core `fbbc0af832e9525d1ad96ede021bcf6000f28362499cb7f775906d074b6c5c46`、
DraggingDetect `bda1fc35092fdc3bf954fcda0a5c3309b2bc8808cf4c3a6803928a7a288b0306`：
字幕专项普通 `VizmOm`／ASan `xV8jC5`／TSan `mco2oW` 各 **408/0**。五精确负控
`jnwQUb` 22/5、`08GtaI` 408/36、`AuafNg` 408/31、`Wf9MJ9` 408/5、`pTVk3Q` 9/4，
子进程均正常退出 1，validator 接受确切失败集合；针对性 22／9 项不当成全套正向。
根代理独立核对八份 source-before 完全相同、source-after／生成物匹配及五份 validator。
真实 Session／libmpv、实际字幕 track／vf 和 queue 事件运行；周围 UI／事件服务是
明确边界，不冒充完整 App、字幕像素或真实声卡验收。README 保留中途 fixture 崩溃，
没有把它们算成负控成功。原 DropRouting 104 项保留，加十二项门禁检查后共 116/0。

六套旧抽取器已明确抽取真实窗口 helper，MPV-only 边界误入窗口投影即失败；原断言
不减。`window-extractor-audit.neSR8V/commands.txt` 记录 Core `f5a3df8a` 时的 21 个
编译变体（非行为通过）；根代理在最终 `fbbc0af8` 上重跑受控生命周期 TSan 41/0 及
两个原负控，不能当成真实 Session／完整窗口结果。新专项加入 CI，自动更新身份、
默认后端和正式发行不变。

### M4 AV1 独立验收包（目标报告异常退出，硬解未验收）

续播候选另已冻结推送为 `8cb9f7f86e93207fd7b76f4502ffa9198fab21a8`，开发 CI
`38410825481` 于 2026-10-13 14:08:37 UTC 启动，已失败且 App 上传关闭。
两个 job 均在 SeekTiming runner 提取 `MPV_EVENT_PLAYBACK_RESTART` 时失败：新 native 队列
路由和原 `handleEvent` 有同名 case，原 helper 要求全文件唯一。未进入该步真实 seek 断言，
不是已经证实的 seek 行为退化。修补仅限定唯一 `handleEvent` 方法内提取，保留全部原时序、
token、readiness 与生命周期断言；12 项 parser 正负控、普通行为 37 项和旧 exact-seek
方法负控通过。`--live --deps-dir deps` 的 37＋38 项通过，使用本机旧双 ICC 补丁库
（SHA `5a76b8188eecf781a22567f6902f67e8da82da99495e633da1aa2d3edd65e81e`），
无窗口 `vo=null/ao=null`，不能替代候选库或完整 App CI。稳定基线只有一个同名 case，
此失败不影响独立的 Finder 标签稳定分支。
原 95／54 和新增续播 writer 44／reader 10 均须实际 CI 验证，不能以准备检查 59/0 代替。
发布前两个 P2 见续播设计末节；此轮不改默认、不创建发行。

`Tools/NativeAV1Tests/Portable/` 生成不依赖目标机开发环境的离线包，复用已有精确身份的
arm64 解码测试与五个播放库，不重签名、不安装 App。要求 macOS 26+；包内含合成素材、
原许可证及 16 份锁定上游对应源码，既有项目构建材料仍完整保留。
第一版包位于 `build/m4-av1-acceptance.pc6dued3.noindex/M4-AV1-Acceptance.zip`，
62,464,107 字节，SHA-256 为
`394f60c480022355e86b46b8d9db923b782ea7242d1f868955edd99dcd4ac7d3`。
主代理独立重跑 14 项离线测试及该包 `--verify-only` 通过；后者只记
`VERIFIED_NOT_RUN`，不能作为硬件通过。原目录与 ZIP 移位检查通过，实际 M2 strict
运行为 1738 项中 18 项失败：两种位深均软件回退，正确拒绝 PASS。
运行前后 SHA 和五库实际加载位置验证通过，不把软件回退说成 M4 已验收。
用户可将整包拷到 M4 Max、双击 `Run-M4-AV1-Check.command` 并回传单个脱敏
`reports/run-*/report.json`；不会联网、读取私人媒体或自动修改权限。系统阻止运行时
记录提示，不解除安全限制。SHA 用于检测传输损坏，不是发行者认证；无 Developer ID
签名／公证。该包不证明完整 App、4K 长时性能、HDR 屏幕或真实音响验收。

目标机报告已收到：arm64、macOS 27.0，运行前后 SHA 均通过，但测试进程收到 SIGKILL
（9），没有返回实际解码计数或库加载证据。原报告将信号退出误写成 normal，exit_code=0
也不代表成功；缺少输出不能证明进程未进入 main，更不能据此断言 AV1 不受支持或认定
Gatekeeper 是唯一原因。原报告与第一版 ZIP 保留，不覆盖或重签名。

新诊断包为 `build/m4-av1-acceptance.sb9syqua.noindex/M4-AV1-Acceptance.zip`，
62,467,202 字节，SHA-256 为
`d8c7ed86c931378f310ffba141ee906ecc98eee57cf439fd4d4050899408e3ac`。
同一锁定二进制与库不变，启动器新增六文件的有界只读签名／隔离属性状态，信号退出码
为 null，并记录输出字节、dyld 行与摘要数量，不采集原始输出或修改安全策略。
主代理独立 19/19 离线测试通过；新包 verify-only 报告 `run-5DM5FkIL` 为
VERIFIED_NOT_RUN，实际 M2 报告 `run-lK7UPcqj` 为 1738 项中 18 项失败、两位深各 24 帧
软件输出，明确不是硬解 PASS。六个签名完整性检查通过，库加载和前后 SHA 正确；这些
本机结果不能证明 M4 上的启动策略或硬件路径。

新版目标机诊断已回传：六文件 codesign strict 完整性验证均通过，六文件 quarantine
均存在；仍 SIGKILL(9)、0 输出字节，无 dyld 及解码摘要。用户随后截图证实系统先后阻止
`libswresample.5.dylib` 与 `libswscale.8.dylib`，需要放行后重新运行测试，旧进程不会恢复。
用户已单独确认允许对已校验包定点移除隔离属性；提供的 M4 命令先用固定 SHA 验证
`Run-M4-AV1-Check.command` 与 `verify-and-run.pl`，再以 clean environment 执行
`--verify-only` 校验全部包内容，成功后仅对测试程序和五库逐项移除 `com.apple.quarantine`。
没有递归处理目录、sudo、改全局 Gatekeeper、重签名或远程执行；原文件内容保持不变。
这只是经授权的测试启动排障，不是安全性、公证或硬解成功声明，仍待新的报告确认。

### 音频设备菜单的实际换核入口

新发现原生播放时选择输出设备仍直接写闲置 MPV，菜单也错误显示该闲置配置。
已改为经过现有 owned compatibility，并在交接期间拒绝重复选择、禁用菜单和
取消未确认的勾选；原生输出仍使用系统默认设备，idle 启动 fallback 仍同步执行。
冻结 Core `14d8d140`／Menu `4193310d`；没有新增物理声卡选择实现或改变默认后端。

`Tools/NativeAudioDeviceTests/` 复用实际 Session／libmpv／整表安装器，抽取真实
Core、AppDelegate 和菜单入口。原实现 `t9BVrJ` 31/16；最终普通 `D5ogVc`、
ASan `8tUPGl`、TSan `2odrPO` 各 90/0，主代理独立普通 `JnTU9P` 亦 90/0。
三种精确负控分别只产生预期 35/84、10/90、5/90 失败；主代理复核源码清单相同、
前后不变及生成物 hash。覆盖单片／队列在采点、真实加载事件及精确 seek 中停止后
同 URL 重开，不允许旧设备动作落到新媒体。发现过程及测试边界保留在专项 README。
设备枚举、App 服务及事件转发是明确边界，音频为静音；不是物理外设、可闻声音或
完整 MPVController／整窗验收。CI 已增加同源三模式、三负控及失败证据留存；
已结束的 `38361506765` 不包含该后续修补，须另行验证。

### 真实 EOF 后变速与首次重播

音频时序审查以实际 FFV1/PCM、H.264/AAC 播放复现：原 Session `5542c267` 到
EOF 后 `setRate(0.8)` 会 seek 到 `duration - 1 microsecond`，抹掉 ended 状态；
首次 resume 随即再次结束。原速对照均正常；`native-rate-eof.XTH30V` 为 34/2。
Session `aab38cba` 只在已结束且 decoder／媒体 revision 有效时发布新 rate，
不刷新尾帧队列，保留原有 resume 从头开始逻辑；非 EOF 路径不变。

最终专项普通 `GY9B0L`、ASan `M7VAcc`、TSan `h71aZc` 各 64/0，包含连续变速、
不支持速率拒绝、静音和显式 seek 到非零位置后变速。单变量撤回该分支的 `L528c1`
恰为 52/8，主代理独立验证失败集合与身份校验。负控验证器后补依赖校验的 hash
差异明确记录在 README，不把不同工具清单称为完全相同。主代理在隔离 AV1 新库
`7FMHum` 上独立重跑最终专项 `HW6EfR` 64/0、原 Session 普通 `MkRSPe`／TSan
`eQbtj1` 各 209/0及真实图像读回 `TJCI4T` 66/0；源码／生成物／依赖检查通过。
原 A/B 普通／ASan／TSan 各 151/0（统一证据 `native-ab-rate-review.ImjZC5`），
其旧 runner 使用既有 deps，不冒充新 AV1 依赖运行。

CI 增加该专项三模式、精确负控及证据保存；完整 App 检查前移到生产构建后，
保留所有既有断言、超时和隔离清理。仅 workflow_dispatch 在失败后继续采集独立
检查结果，稳定发布仍被失败拦截。已结束的旧 CI 不受本地顺序改变影响，也不包含
此 EOF 修补。完整日志确认其 surfaces／route step 在 Surface 106/0 后因
run-video-view 旧 fixture 缺 generic 退场接口而编译失败。
已补 nil-only、误入 generic owner 即失败的边界，保留完整生产退场方法；route
返回实际递增 UInt64。普通／ASan／TSan 各 51/0；原两个负控精确为 48/3、47/4，
无崩溃或编译错误。五轮源清单完全相同、source/generated 重验通过，证据与原样
修前编译失败保留于 `build/video-view-generic-boundary.gtTwyX`。这只解释该步编译
失败，不解释整窗失败。独立 Surface 几何与真实源像素本机 106/0 于
`native-surface-tests.U2Frqy`，不等同物理屏幕合成或 HDR 验收。

### 冻结 35d99248 的完整 CI 结果

`38361506765` 的完整生产与隔离 App 均编译成功，但整窗为 **76 项通过、1 项失败**。
先前异步 Session 获取、A/B 标记及暂停绿色目标均通过；
`handoff_native_nondefault_state` 在总计 16.1096 秒失败，约在前一绿色目标检查后
17ms。驱动尚未发出实际音频延迟菜单交接，不能把后续 MPV 恢复或退出记为通过。
独立 54 项队列进程未启动，隔离 App 清理完成。原始报告、构建和运行日志保留于
`build/native-ci-38361506765-app.7BTZsD`。当前正在区分异步重新预缓冲与真实状态问题，
不根据时序猜测直接宣称根因或放宽检查。

完整 job 日志还确认：URL enqueue 普通与 TSan 正向均为 **118 项中 1 项失败**，
失败项是 `Rejected enqueue preserves the existing compatibility action`。虽然该 step
被标为 success，旧 Bash 3.2 复合 `[[ ... && ... ]]` 裸门禁未可靠传播子进程失败；
因此本次不认定 URL enqueue 通过。原日志与原 runner 保留于
`build/native-ci-38361506765-final.nRD4ue`，fixture 和明确退出门禁正在修补。

后续 fixture 修补只补入真实 `fileStarted` 的媒体 generation 和 generic owner
receipt 更新，不修改生产或原 118 项断言。普通 `9q5VEW`、ASan `umevIF`、TSan
`umbESL` 均 118/0；原八负控与历史失败列表逐行一致（27/9/7/2/3/4/2/2），新增
`missing-generic-start` 只触发原失败一项。三个源清单相同、前后检查通过，主代理
独立重验通过；保留只修门禁而尚未修 fixture 的 `emJEJZ` 实际 118/1、runner exit 1。
URL 与 rotation 同型门禁均改为明确退出，实际 gate 在系统 Bash 的九种退出组合
自测通过；只还原旧门禁则恰有七种错误被漏报。此为测试可靠性修补，不声称生产换核
功能因此完成。工具证据见 `build/url-enqueue-generic-receipt.Ze2iQ2`。

同一次 CI 的独立队列模型普通／TSan 各 155/0、实际整表安装器普通／TSan 各 207/0
及七精确负控通过，半建列表取消 TSan 200 次共 600/0。CoreQueue 三模式各 206/0，
generic handoff 三模式各 218/0 及十一精确负控通过。这些真实局部结果不能替代
完整 App 失败，也不能解释或抹除此前 partial-cancellation 的偶发失败。

### 非默认播放状态的有界整窗准备

随后真实 CLI `native-app-paused-wait.PnJ8Ui` 自然复现立即变速 query 为 unavailable、
稍后实际 worker 与绿色输出准确就绪的一处测试缺陷。原 CI 没有记录该查询结果，
不能据此断言其唯一根因。新 single／queue caller 复用原 paused helper 的单一
12 秒 deadline，最多一个查询在途；37% 音量仍用原 1e-6 容差，其余调用保持精确零，
位置、1.25x、实际绿色像素、A/B 标记、viewport 及同一个窗口／Session／媒体／native
输出身份仍必须同时符合。没有修改生产代码或原 92/54 labels、110/150 秒总限制。

driver `4926aeb4`／probe `872f9502`／runner `018bb559` 最终 CLI `rUhGfd`
包含六模式：普通延迟准入通过、原过早 nil guard 精确失败、旧一次性 handoff 精确失败、
新等待通过、只撤等待精确失败、只撤 owner 检查时错误接纳替换媒体被精确检出。
所有编译退出 0，子进程状态依次 0/1/1/0/1/1，wrapper 0，清理和 source/generated/deps
检查通过。确定性检查通过有界屏障排序真实 worker 的 rate 与 capture，阻止调度运气
掩盖旧缺陷；没有注入 ready／像素。45 项准备测试通过，根代理独立重跑及独立审查
均通过。仍须下一完整 App CI 验证菜单、几何及实际两核交接。

新退出门禁的 rotation runner 由根代理普通重跑于 `Q1bAQC`：正向 176/0，四负控
4/10/2/48，runner/source/generated 均为 0；该轮未跑 sanitizer，不使用旧 CI 的
sanitizer 结果冒充当前源码。未发布、未更换默认内核或用户安装。

显式有界列表已接实际 Core、native Session 与 MPV 命令；周围 App 服务边界见
`Tools/NativeCoreQueueTests/README.md`。生产 controller 的停止协议单独测试：
当前条目真正卸载后才能清理精确 owner 的列表，reader 事件排空后才能确认 idle。
事件隔离必须先于 stop route 启用，包括后台任务推迟发 stop 命令的窗口。

controller `c06561e7` 通过普通 206、ASan 217、TSan 225 项及十二个精确负控；
计数差来自主队列等待检查。后续音量事件补丁 `8f2d804a` 通过普通 210、ASan 237、
TSan 232 项及新的 pending-volume 负控；旧十二控本轮未重跑，CI 将包含它们。
安装器 `ed5d25f9` 三模式各 207 项及七负控通过。主代理独立
`mpv-queue-installer-tests.tkDHUj` 在隔离 AV1 播放依赖上亦通过，源码／生成物／
依赖身份校验保持完整。这不解释或抹除旧 CI partial-cancellation 191/1。

审查新复现运行中自动下一项偏好、队列交接中音量／速度意图丢失，已修补。
冻结 Core `a30bcd00` 的实际 Core/Session/MPV 集成普通 `8TH6bc`、ASan `RD4anl`、
TSan `HRuQt2` 各 206/0，source/dependency/generated 前后身份校验通过；18 个扩展
负控全部产生精确失败，wrapper 均为 0，完整证据表见 CoreQueue README。
旧静音开片 ASan 363、受控 Core TSan 41 与两负控、
lifecycle 76 也在该 Core 上通过；Rotation/URL 本轮仅类型检查，不冒充 GUI 实测。
后续普通单文件 generic compatibility 已补独立 action UUID、媒体 epoch、
实际 route revision 与 capture／retire／start／restore 阶段所有权；URL 只作额外检查。
冻结 Core `bbd871b4` 的新专项普通 `DDXugx`、ASan `rpmA43`、TSan `oUxbJF` 各
218/0，实际 setter 已复现并修补旧回调覆盖新音量／速度，以及捕获取消后支持范围内
的新意图丢失。完整发现历史与测试边界见 `Tools/NativeGenericHandoffTests/README.md`；
十一项精确负控全部准确触发预定失败，完整表见 README。主代理另外复核 13 份
sanitizer／负控源码清单均与普通运行一致，exit-status 为 wrapper 成功、
source-comparison 为空且生成物 hash 有效；不把故意失败当生产测试失败。

菜单／既有侧栏／原始和 typed 快捷键已保护半加载窗口；既有剪辑面板的预览、
自动 debounce 与采点也受门禁保护，内部 A/B／viewport 恢复仍可执行。实际 libmpv
预览专项 42/0、工具 UI 17/0，撤 controller／bridge 门禁的两个负控分别准确失败
1 项，证据 `build/generic-preview-admission.8M2B2R`。它控制 busy admission，不冒充
完整 Core 事件桥接。根复测静音开片 363、菜单 14 加 23 入口、预览导航 317、
侧栏 lifecycle 190 加 4 source 检查均过。受控 Core 41 加两负控本轮亦通过；
CoreQueue 普通加 18 负控仅重新生成和核对唯一替换点，不能继承旧 Core 的运行结论。
旧 Rotation／URL／AB／NativeClipPreview／NativeViewport 仅补接口并编译，
完整 App 与新同源 CI 结果尚待确认。当前仍不切默认或发布，能力门禁与发行身份均不变。
以下历史候选与失败保留各自源码身份，不当作后续 Core 变更的验收。

### AV1 与队列后续切片（2026-10-13，未切默认）

播放 FFmpeg 7.1.5 已加入 SHA 锁定的开源 AV1 VideoToolbox backport；原补丁与
ChengYing 的资源错误修补分开记录，并进入源码分发清单。新 CYN 明确选择支持 VT 的
`av1` decoder，初始化不可用时才回退 `libdav1d`；首帧前最多保留 64 个／8 MiB
压缩视频包，不重放音频、不倒退 demux 游标。已有实际视频输出后的错误不会被伪装成
无缝软件回退。动态 HDR、默认准入和旧 MPV 兼容边界不因此放开。

已通过真实函数负控定位并修补 AV1 `ff_get_format` 吞掉资源初始化错误、OBU append
失败仍提交截断数据，以及 CYN context 分配失败误标 Unsupported 三个问题。最后一项
会使 App 错误地尝试格式兼容重试；现在明确为 ResourceLimit。最终源码 CYN SHA 为
`e3bcc18ecde84e48cf5556308eac7fc9802d6e5818ceecabe5b85e738b8958b9`。
新库独立构建到 `build/native-av1-playback.7FMHum`，没有覆盖原 `deps`；详细正常／
sanitizer／故障注入、保留的历史失败、补丁来源与 M4 命令见
[AV1 专项说明](../../Tools/NativeAV1Tests/README.md)。本机 M2 正常软退不能充当 M4 硬解。

同一新库和新 CYN 的真实 session 普通／TSan／ASan 各 209 项通过，证据分别为
`native-playback-session-tests.FNF2F6`／`TAmCkL`／`ESDZO1`；真实显示读回 66 项通过于
`native-playback-rendered-tests.5IGfEG`，源码、库／SDK 与生成素材前后身份校验均通过。
这些是独立 session 和渲染窗口，不是完整 App、目标 M4、可听输出或实体 HDR 色彩验收。
较早同库／旧 CYN `acb0f798` 的结果保留，但不再代替新 CYN 的回归证据。
两个 runner 新增可选 `NATIVE_PLAYBACK_DEPS`，默认仍用仓库 `deps`；完整校验候选
9 库的安装名、rpath、依赖闭包、签名、架构与 SDK，记录实际库／头文件前后 hash。
候选缺失时失败，不静默改用旧库；测试环境有 DYLD 覆盖时拒绝运行。helper 六项正反
检查通过，默认旧库及独立新库均实际通过身份验证。生产构建路径不变。

新增 `NativeQueuePlan`／`NativeQueueState` 和
[独立队列验证](../../Tools/NativePlaybackQueueTests/README.md)，只证明状态决策，
当时尚未进入 Core／Session／Xcode 工程，后续集成见本节。正常／ASan／TSan 各150项通过；三个单变量
负控分别产生准确的 4／7／1 项失败，主代理独立复跑于 `native-queue-model-tests.QuuVBv`。
真实 libmpv 导航探针纠正了“末尾 next 总是 no-op”的错误假设：off/file 保持末项但
生产入口会暂停；playlist 实际回到首项。探针没有执行后续 AppKit 自动恢复。
独立完整队列的真实 MPV 安装器已实现，Core 接入仍在进行；不能把模型 `verified`
字段当外部安装证据。安装器普通／ASan／TSan 各 191 项，六精确负控分别失败
14／2／1／2／2／1 项；主代理实际复跑于 `build/mpv-queue-installer-tests.2QRfgj`。
真实 `vo=null`／`ao=null` 结果不证明窗口、图像、可听输出或位置恢复；见
[安装器说明](../../Tools/MPVQueueInstallerTests/README.md)。

随后实际 `MPVController` 新增安装专用的带 owner 事件桥接与真实 MPV node 读回。
reader 立即复制 START／END entry ID，FILE_LOADED 绑定前一 START；异步交付再次核对
owner，新安装不继承旧 START。安装期间抑制普通 UI／媒体事件，但保留 hook 继续、
shutdown 清理及显式 overflow 失败。缺 handle、返回码／属性读回失败不会当成成功。
Xcode 同时登记模型／安装器；最初新增 Queue ID 与 Surface 重复，提交前改为独立
ID 并核对 1,979 个对象唯一性，`plutil` 语法检查不能单独发现这一重复问题。

桥接最终普通 115/0、ASan 116/0、TSan 117/0；四个撤销门禁的精确负控通过。
冻结 SHA、全部证据目录、首轮脚本编译失败和真实测试范围见
[桥接说明](../../Tools/PlaybackBackendRoutingTests/README.md)。同名 URL 的真实
两项列表完整安装到第二项；不能把它写成尚在实现的 Core 导航或整窗交接通过。
CI 新增两项 owner／START 负控和失败证据留存，旧 gate 负控保留。

开发 CI `38329363769` 冻结于 `7f7e4bcc`，已失败，既不包含上述 AV1 代码，也不包含
独立队列模型。当前没有新增版本、发行包、签名变化或更新源变化。
后续开发 CI `38337569102` 冻结于 `e4369f41`，纳入新 AV1、独立模型／安装器和
关闭 layer 修补，已失败；不包含后续 controller 桥接或 Core 队列接线。
生产／测试 App 编译、media-helper 与 AV1 检查通过。独立安装器普通191/0及六负控
通过，TSan191/1仅 partial cancellation 清理检查失败，尚在定位；不能用本机通过
覆盖这次失败。队列证据为 `build/native-ci-38337569102.GQRT14/queue`。

### 最新整窗阻挡（2026-10-13）

后续本机对安装器补有界取消诊断和候选依赖身份校验，没有改变生产安装器或放宽
期限。新 AV1 播放库下普通／ASan／TSan 完整检查均为191/0且六负控准确；最终
runner TSan复验于 `mpv-queue-installer-tests.8IDtyH`。另200次半建列表取消为600/0
（`FtLwVq`），只是尚未复现，不代表下述CI的partial cancellation故障已修复。
CI将保留实际返回码／列表ID和新的重复取消证据；详见安装器README。

最新 `38337569102` 的原92项整窗驱动完成70项通过、1项失败。下述关闭layer检查
已过，嵌入字幕回退也通过；后续新core开片的 `handoff_native_paused_red_ready` 在
约2ms立即失败。真实inventory异步创建session，而helper入口先guard session非nil，
没有进入原12秒poll。后续已补异步session获取，仍是单12秒期限，前后核对相同session
和媒体代次。真实Session局部正反对照通过，最终证据为 `native-app-paused-wait.XFSltk`；
旧guard控制在创建Session前明确失败，未放宽像素断言。准备测试42项通过
（`native-app-queue-final.trDWRE`），不能改写原CI失败。
加载后交接和终止检查尚未执行，完整App仍未过关。隔离App清理完成，原始证据在
`build/native-ci-38337569102.GQRT14/app`。以下保留关闭问题的原复现与修补证据。

新 driver 保留原92项，又新增同一测试build的独立46项队列进程；重复URL、真实帧／
时钟、音量归零、off/file/list EOF、精确整表回退、菜单动作和两core关闭均须实际验收。
每个进程的110/150秒限制不变，新增source／App／fixture前后身份检查及失败证据留存。
这些新整窗检查尚未运行。旧单媒体夹具只补显式无队列边界，原断言保留；最终同源CI
与本机rotation焦点前置失败仍待核实，详见
[夹具适配记录](2026-10-13-native-queue-fixture-adaptation.md)。

后续开发 CI `38329363769` 的完整生产／测试 App 编译及 media-helper job 通过。
92 项驱动实际完成 **66 项通过、1 项失败**：菜单入口、实际自动预览、连续输入、隐藏后
循环、停止恢复、延迟首帧、连续换片和音量归零通过；第 67 项
`preview_window_close_cancels_and_detaches` 失败，后续兼容交接和退出检查未运行。
关窗时 native session 和预览已结束、状态为 idle，但旧 display layer 仍挂在 surface；
`retireNativePlayback` 没有明确释放画面挂载，原有 detach 只发生在下次切换 surface 或
最终 `uninit`。修补在主线程 retire 开始时仅解除该会话的精确 output 挂载；不调用
`uninit` 或切换到 GL，空闲原生视图仍可复用。Core SHA 为 `0efaa1e6`、VideoView 为
`2448918a`。原实现的实际 View／抽取 retire 复现为 42 通过／2 失败；修后普通／ASan／
TSan 各 51／0（`xyjCHb`／`LMXztz`／`aa17TG`），撤掉 Core detach 为 48／3
（`4JRujK`），撤输出身份保护为 47／4（`7Ssxh6`）；皆有完整摘要与输入后验 hash。
这些目录共用 `build/native-video-view-tests.` 前缀，实际目录以前述测试输出为准。
真实 Session＋VideoView＋抽取 Core Route 为 335／0（`Xvff9o`），每次 stop 都在
`uninit` 前检查旧 layer 脱离。旧 Core 41 项、预览 235 项、旋转 176 项、URL 118 项及
各自负控通过。没有修改 App 的原断言或时限；新诊断强制先捕获实际非 nil layer，仍须
后续完整 App 独立验收，不把局部测试称为整窗通过。
隔离测试 App 清理完成，原始证据为 `build/native-app-ci-38329363769.h5slWi/`。
以下保留前轮菜单失败历史，不能当作最新仍未通过菜单。

开发 CI `38319384831` 冻结于 `82b40531`，完整生产 App 与测试 App 编译成功，
media-helper job 和之前的独立 native 检查通过；完整 App **43 项通过、1 项失败**，
失败标签为 `preview_real_tools_menu_attached`，后续预览与退出阶段未执行。
不能将准备测试中的预期 `TERMINATION_PROBE_FAIL` 负控当作此次失败原因。
隔离测试 App 清理完成，证据保留于 `build/native-app-ci-38319384831.UfOmmJ/`。

已定位实际生产入口差异：`MainMenuActionHandler.canShowVideoTools` 读取
`PlaybackInfo.isAudio`，它只按 MPV 的音／视频轨道数组分类。native 路由故意不伪造 MPV
轨道，两数组为空时得到 unknown，因此菜单动作即便被 `NSApp.sendAction` 正常分发，
内部 guard 仍拒绝打开工具面板。此前日志 `sidebarHidden=false` 只说明没有自动隐藏，
不证明工具面板已经挂载。候选 driver 已增加实际 sidebar 状态、tab、panel 数量／挂载和
控件就绪的有界诊断，不改原 92 个断言或运行期限。准备测试 31 项通过，不是整窗通过。

后续提交 `3cba854c` 的 92 项驱动以及 `37a532d8` 的旋转交接不在该失败 CI 中；
必须由修补后的独立运行验收，不把不同源码的结果混写成一次成功。

最小菜单修补改用已完成准入的真实 native `media.hasVideo`，不填造 MPV tracks；
加载／本地文件存在／窗口可见／非迷你或交互模式等门禁原样保留，旧内核仍使用原分类。
`Tools/NativeVideoToolsMenuTests/run.py` 机械抽取实际菜单、分类与准入方法，并用真实
AppKit 分发；普通／ASan／TSan 各 **151 项通过**，恢复原门禁的单变量负控恰有
native 视频的菜单校验和实际面板请求四项失败（退出 1，编译和分发本身正常）。
窗口与 decoder 元数据在此是显式边界，不是实际 nib 或预览图像验收。
证据前缀 `build/native-video-tools-menu-tests.`，四次后缀分别为
`tbzbzstq`、`x1bpu_ko`、`gnfffpj6`、`3cjkbtds`；源码及生成输入的后验 SHA 均一致。
旧菜单路由 9 项及 22 个入口检查通过；完整 App 的原面板断言与超时不变，等待新 CI。

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
seek 到 2 的首个实际读回是 `raw nil`，约 12.5 ms 后是正确 NV12（距首次入队约 14.3 ms）；
两时钟均为 2、rate 0，
flush 完成、renderer 无错误且 `isReadyForDisplay=true`。这只能证明该次短暂空值存在，
没有复现原三秒失败；不能据此把 ready 标志或追加帧当作生产修补，也未继续重复碰运气。

后续只读复核 `7te25h` 和 `5n25Go` 的暂停入队记录，尚无证据表明当时 parent／renderer
时钟不同步；原失败又发生在新建 output 的 paused open→seek，不能先假定是旧高位时钟。
本机 SDK 的 `copyDisplayedPixelBuffer` 合约允许图像不可用时返回空，非零速率必为空；
`readyForDisplay` 只描述首帧就绪，并不保证同一时刻能复制像素。三秒读回失败仍保留，
但不单凭此判定实体屏幕黑屏，不添加尚无证据的生产锚点修补。

上述开发 CI `38305625981` 最终失败：媒体 job、完整生产 App 编译、decoder 全部检查、
output 96、display 36、普通 session **209/0**、实际像素 **66/0** 通过；随后 session
TSan 为 **208/1**，唯一失败是 `[0.5,0.9]`、速率 1.2 的 A/B 在固定 1.5 秒内只有一次
已提交视频时间戳回绕（65 samples、phase seeking），未达到至少两次。没有 TSan race 报告；
尚不能判为永久卡住、生产退化或单纯测试时间窗错误，不改期限、不抹去失败。
日志保留 `build/native-ci-38305625981-build-failure.log`。本轮没有跑到完整 App 47 项。
后续手动开发 CI 仅在生产 App 已编译且未取消时继续采集各独立 native 套件和实窗证据；
失败仍使 job 失败，打包与发布的成功门禁不变，没有 `continue-on-error`。

### A/B 截止失败采证（不是播放修复）

一次同前序的隔离 TSan 诊断 `build/native-ab-deadline-diagnosis.5n25Go/` 为 **209/0**，
记录到两次回绕，seek 至首视频提交分别约 66.3／75.6 ms。这次成功不能解释或撤销上述
CI 的 **208/1**；原始日志不足以区分解码、系统输出及调度等待。

已把有界数值时间线落入 `Tools/NativePlaybackSessionTests`：原 **209 项、1.5 秒观察、
120 秒看门狗**不变，原失败判定完成后才输出最多 512 条 sample／snapshot 记录和一次
最多 1 秒的 worker 输出状态。额外诊断不提供再次通过机会，不以 readiness 证明显示。
输入源码、七份合成素材及运行模式都保存并复核 SHA-256，CI 仅上传日志与校验清单。
ring 锁和数值采样本身有观测开销，不把新诊断运行当作原始失败条件完全不变。

普通运行 `build/native-playback-session-tests.sFtiQU/` **209/0**；仅在临时测试副本将
deadline 结果强制为 false 的 TSan 负对照 `3P4rJx` 实际仍得到两次回绕，但严格保持
**208/1、退出 1**，输出 224 条记录、零覆盖及 worker 状态，未出现 TSan 报告。
原暂停 seek 图像 **116/1** 和 CI A/B **208/1** 仍是待定位问题，没有新增发行。

暂停读回另补 `Tools/NativePrerollAudioTests` 的最多 1024 条数值记录，区分 renderer 原始
nil、尺寸／像素格式／planes／lock 错误，并记录实际 timebase、flush、ready 状态及窗口
附着／可见性；不保存像素内容，不扩展原有 FIFO 预算断言的 Session 可变字段反射。
保留原 **117 项、3 秒读回时限和进程看门狗**，只有原断言失败后才输出时间线。
新诊断 TSan 首轮 `build/native-preroll-audio-tests.iv5xTc/` **117/0**；只强制一个
读回判定为 false 的 TSan 负对照 `1VBFDZ` **116/1、退出 1**，记录 330 条、无覆盖。
即使负对照实际读到了图像，也不会把失败改判通过；两轮无 TSan 报告、所有源码及六份
合成素材后验 SHA-256 均一致。这是采证能力，不是原 `twnu4i` 偶发故障的修复或解释。
随后按事先固定的两轮 TSan 复现计划串行运行原完整前序，`3uuAgw` 与 `hJ1r2H`
均为 **117/0**；素材仍有真实 75 个 B 帧，前后源码／素材 hash 一致。没有为等到通过
追加无限重跑；两轮没有再现旧问题，不改变旧失败未定位的结论。

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

## 原生剪辑预览与兼容交接（专项通过，完整 App 待运行）

原生 `.tools` 入口不再一律切回 MPV。时间输入自动 debounce 0.35 秒，第一次预览从实际
worker 时钟保存 position、暂停／EOF 和可选 A/B 基线；修改范围保留最初基线，停止先还原
A/B 再定位，避免临时预览区间夹住返回位置。音量、速度、画面变换与单文件循环不被旧基线
覆盖。EOF 恢复保留“已到片尾”语义，一次播放即从头开始；显式 seek 清除此标记。

输入、采点、停止、用户 seek、A/B 键、换片、退场各有媒体代次与用户意图检查。
无效输入暂停临时循环而保留返回基线；自动隐藏播放 chrome 不等于关闭工具或停止预览。
截图采点保留起点加五秒规则；旋转仍显式回到兼容内核。导出等待预览状态还原，导出任务
本身不在新播放内核重写，也未改变原 HDR／品质约定。

真实 session worker 屏障复现了旧兼容采点覆盖同文件新预览／暂停：
`build/native-clip-preview-tests.jgMAFS/` 为 197 项／4 失败。第二段采点和重试已增加意图检查，
但该检查最初也会取消尚未 ready 的必要回退；`vOeFEA` 为 201／3，保留失败证据。
单纯豁免初始检查仍会丢失 sleep 的显式 pause（`i1IouH`），所以新增独立可选开片意图，
在初始回退时沿用最后 pause/resume，没有显式操作时仍遵守原开片偏好。策略基于发起与
当前 readiness，不依赖 reason 文本；进入 ready 后的新操作重新具有取消旧交接的优先级。

冻结生产 `PlayerCore.swift` SHA-256：
`38c30207d79f5e6555ce98339e85f2987944c4c546c4285b943a62a52b1db8ea`。
新 `Tools/NativeClipPreviewTests/run.sh` 普通、ASan、TSan **各 235 项／0 失败**，分别保留在
`build/native-clip-preview-tests.wr18yT/`、`e0RbSc/`、`ZG3l5M/`；源码前后与生成源码／fixture
SHA 校验通过。真实 decoder/session/transport/output 与机械抽取的 Core／面板方法参与，
MPV 加载、完整 nib 和面板布局仍是明确边界。不能据此宣称完整跨内核画面交接通过。
同源四个单变量负控均退出 1：撤销请求取消 `VVDumK` 为 235／4、撤销采点取消 `bsnD6i`
为 235／1、撤销 EOF 标记 `TDe8hw` 为 235／3、撤销兼容意图门禁 `IQVNi2` 为 235／5。
七轮源码前后相同，生成文件校验通过；未知负控模式实际退出 2，没有误跑正向后记作通过。

旧回归证据为 `build/native-preview-legacy-regression.8pyWN7/RESULT.txt`：导航 317、
VideoTools 三语言各 942 UI 与 132 task、真实 libmpv preview 324 项与 300 帧、viewport
两语言各 1098、native viewport 172、route 48、A/B normal/TSan 各 151 均通过。
这些随本轮开发执行，不是最终冻结整窗验收。最后只新增 fixture 声明后补 ControlledCore
41 项和 Live build-only；编译测试 App 的 owned workspace 清理通过，未重跑 GUI。
后者记录于 `build/native-preview-intent-regression.qx6e58/RESULT.txt`。

完整 App 驱动保留原 60 项，新增 15 项真实菜单、AX 时间字段及 AppKit delegate、预览按钮、
slider、实际 chrome 隐藏和在已应用预览时关闭窗口，共 **75 项**。隐藏循环要求五秒内两次
实际共享时钟回绕，不把播放中的 paused-image API 当作显示证据。暂停还原仍验证源像素。
驱动准备测试 29 项通过，含 73 个像素／音量比较、46 个几何检查及 macOS 12 可用性负控；
**尚未实际执行完整 App 75 项**。本机没有安装或运行正式 App，未改变用户配置或系统权限。

较早 `bea876ea` 冻结候选的 CI `38310346836` 已跑完整 App **60 项中的前 59 项通过**，
最后 `all_real_cores_shutdown_before_termination` 失败。包含真实显示像素、viewport/A/B、
延迟首帧、快速换片、实际字幕兼容回退；不能把部分通过说成完整验收成功。
生产和测试 App 编译、前置独立内核及延迟首帧阶段通过；artifact `summary.json` 确认
退出码 1、owned cleanup completed，普通发行构建没有测试驱动。证据只读下载于
`build/native-app-ci-38310346836.vnHcRF/`。它不含本次 preview 235／App 75 或新诊断。
生产注册表没有正常关闭时删 core 的代码；现有 artifact 未保存各核末态，不能将失败
归因为列表清空。driver 原退出请求来自 `captureCurrentState` 的 main GCD completion，
而异步关核也依赖 main GCD；生产 MPV 发起退出已有 common RunLoop 入口避开此问题。
无窗口真实 `NSApplication` 双对照 `build/native-termination-context.8n2vix/` 复现：
GCD 发起 `.terminateLater` 时，一秒 common Timer 截止两个 main.async 关闭回调均为零、
退出 1；只改 common RunLoop 入口则两回调完成、退出 0。未生成／安装 `.app`。

新 driver 已采用 `performTerminationFromRunLoop`，不预先关闭 core、不延长 deadline。
原 count≥2、所有 registered core `.shutDown` 门禁保留；另强持有实际两核，验证原生
session/output 和 GL context 已卸下、已加载 VideoView 完成 uninit、原生层脱离宿主。
输出无路径的各核状态、通知数、资源布尔值和耗时；未加载窗口不为诊断强制加载 nib。
MPV handle 销毁可能在同步 shutdown 通知返回后，因而只诊断指针是否存在、不误作失败门禁。
机械提取实际 driver helper 的真实 AppKit 正向与撤回旧 GCD 的单变量负控均有效，包含在
29 项准备测试中。**这证明测试入口会产生阻塞，不代表新完整 App 75 项退出已通过**。

额外待迁移门禁：

- 正常 native 首次 admission 不由上述预览测试证明；后续独立首开修补和 287 项证据见下节，
  完整 App 的极早键盘／nib 操作仍须单独验证。
- native→MPV 过渡时连续旋转快捷键的累计动作另有后续修补，见下方旋转交接章节；
  原 MPV coordinator 能排队或抽取方法测试通过，不等于完整 App 交接验收。
- 既有暂停图像不可读与固定 A/B 回绕截止偶发失败仍未定位。新增诊断和本次专项通过
  不能取消旧失败记录，也不能据此切默认后端或发布稳定包。

## 首开暂停／继续意图（专项通过，未切默认）

旧实现用真实 session 的暂停探测状态充当用户开片意图：默认自动播放时第一次 Space
可能变成 resume，反过来提前 resume 会让时钟在媒体检查前前进；最终 notify 又可能按
偏好覆盖用户刚刚暂停。`build/native-player-route-tests.7Erktm/` 保留旧实现 **230/16**。
新实现把 `.loading` 到首个 `.loaded` UI setup 期间作为尚未完成的 admission，pause/resume
只记录最后意图，只有原有轨道／HDR／SAR／几何检查通过才真正发出命令。
getter 和 play-button 使用同一意图；兼容采点保留 transport 已接受的较新操作，
不用落后的 worker phase 覆盖。换片、同 URL 重开、停止和关闭仍按媒体代次取消。

冻结 SHA-256：Core `3b62c01141c646931dc434e61bd7a7158495a871dcfe6040f6183138c10f49b0`；
Window `3f55adba31ab41a6bf7f0c0b249af3a3f8a7585fa488806da3d18ef334ec45b4`。
`Tools/NativePlayerRouteTests/run.sh` 普通、`NATIVE_PLAYBACK_SANITIZER=address`、`thread`
各 **287/0**，证据分别为 `build/native-player-route-tests.xqvmka/`、`qLp3Ga/`、`PSbmjJ/`。
保留原 48 项，新增真实 paused 快照延迟交付、两个开片偏好、多次 toggle／真实 button
方法、setupUI 期间操作、同文件重开和停止／关闭／退出取消。真实两音轨素材仍明确回退，
early resume 不得伪造准入成功。首开探测阶段 worker 时钟必须保持暂停。
源码及依赖前后 SHA 一致，生成源码／素材 hash 验证通过，内层期限未延长。

同源三项单变量负控均退出 1：`start-before-admission` 为 **278/9** (`Qs9f2K`)，
`ignore-opening-intent` 为 **277/10** (`4XweOT`)，`ignore-opening-getter` 为 **274/13**
(`yIafyf`)。Sanitizer 插桩不包括预编译 FFmpeg 或系统 framework。
真实 Core／transport／session／VideoView 执行，不代表完整 NSResponder Space 分发、
原 nib 或真实 MPV 交接；NSWindow close 测试通过明确 observer 边界调用真实 Core.stop。

同源旧预览普通／ASan／TSan **各 235/0**，兼容意图负控 **235 项中 5 失败**、退出 1；
ControlledCore **41/0** 和两负控有效，Live **build-only** 退出 0、测试 App 清理完成。
测试 fixture 改用实际 PlayerState 和真实稳定快照投影，未删旧断言。
记录为 `build/native-opening-legacy-regression.QTc9Ra/RESULT.txt`。
root 另核验菜单 9 项＋22 个入口守卫、拖放 ASan 104 项、App runner 29 项通过；
`build/native-opening-root-regression.qNDsLq/` 保留结果。

更早 `8e1fc6bb` 的开发 CI `38316865546` 两个 job 都在旧 SeekTiming
fixture 漏 `cancelNativePreview` 声明处失败，未到生产 App 编译／完整 App 75 项。
只补 MPV-only fail-fast 声明，不伪造 native
成功；37 项 seek 回归和真实 libmpv 38 项通过，后者 `vo=null`，不是画面验收。
此 CI 不含首开修补或 fixture 修复，不修改其失败结果。
在它结束后才派发冻结 `82b40531` 的开发 CI `38319384831`，不含后续未提交的旋转／交接
测试；没有取消旧运行，也未打开开发包上传或发布。
默认仍为 MPV，未改变发行、安装、权限或用户配置。

## 已加载媒体的完整 App 交接验收候选（尚待执行）

`Tools/NativeAppTests` 保留原 75 个门禁，再加 17 个实际菜单／窗口／MPV 状态检查，
合计 **92 项**。新建从未使用 MPV 的真实 core，原生暂停在绿色 4.2 秒，设置 A=0／B=5.5、
音量 37%、倍速 1.25、缩放 1.5 和横纵平移；通过真实音频延迟菜单触发兼容交接。
不是直接调用兼容 helper 并伪造成功回调。必须保留同一窗口／媒体，卸下原生 layer、
Session、Output、Surface，并从实际 libmpv 属性和音量 slider 核对恢复值。
音频延迟最终变为 0.25 才证明延后菜单已执行；暂停后再观察 0.2 秒，随后真实关闭此
窗口并 shutdown，最后继续原先两个 active core 的退出测试，不删除多出的 core。

driver SHA-256 为 `b75335b7f58d3a06c07e3d8a6f13a55b840cba65b16d13c89929f7ae62567b7e`。
本机仅运行准备测试：`python3 -B Tools/NativeAppTests/test_runner.py` **31 项通过**，
包括 macOS 12 正负 typecheck、73 个像素／音量比较、46 个 Surface 几何比较、20 个
新增交接数值比较和 AppKit 退出正负对照。证据 `build/native-app-handoff-preparation.wqaOJe/`，
源码 hash 核对一致。既有 110 秒 driver／150 秒进程期限不变，增加分阶段耗时诊断。
**完整 App 92 项尚未运行**；正在运行的 `38319384831` 仍冻结于先前的 75 项提交。
本机未安装或执行测试 App；MPV 恢复属性不代表物理屏幕画质、音频同步或 M4 硬解验收。

## 旋转交接与取消所有权（后续修补，尚未完整 App 验收）

快捷键和工具面板统一进入 Core 的永久旋转入口。同一媒体在 preview restore、clock capture、
renderer draining 和 MPV loading 期间累计方向；首次请求只产生一次兼容转换，匹配的恢复
位置完成后只向原有 rotation coordinator 提交一次。没有保存／重放 NSEvent，也没有以
已经导出的文件为输入再压一遍。累计值采用有界模四运算，不随按键次数增长。
同路径重开也生成新的 media epoch；旧 ticket、旧失败回调和旧 timer 不能消费新请求。

初版取消整个 restore 的方案虽通过早期 94 项测试，独立审查发现 `.stopping` 阶段的
`pause()` 会被状态门禁忽略，随后无恢复记录的同文件 reload 可能默认播放，故没有采用。
后续实现分离旋转 action 与同文件播放恢复：取消只撤销待导出动作；暂停／继续和三类
seek 保留最后操作，内部恢复 seek 只豁免精确匹配的 restore ID。drain/loading 不向关闭中
的 transport 写命令；恢复后才应用最新目标与暂停。用户重新开片、停止或退出会清除全部。
取消后新按键在 drain/loading 被拒绝，MPV 已 loaded 后才作为独立的新 coordinator 请求，
不能复活旧 action 或改写原恢复目标。原 busy 错误保留，不被入口覆盖成“没有本地视频”。

冻结 Core SHA-256 `db1727d3e7ff1c6e13193b251479bc86b014de1b2ad6a6dc048dc14a44c4e7c7`；
Window `502c2d0647cd2e72d3b7380d4a1ef16ef0216d9fc247fd79883e8f5713950b10`。
新增 `Tools/VideoToolsRotationIntentTests` 直接编译生产有界状态值；
`Tools/NativeRotationHandoffTests` 机械抽取实际 Core／窗口／面板入口和三个生命周期子块，
实际 coordinator 处理提交，但 native capture、renderer shutdown、MPV events 与导出服务
明确为受控边界。它不是实际导出文件、完整 nib、OS 键盘注入或真实渲染验收。
此切片保留采点时的 volume／rate／viewport，不增加交接中修改这些值的新能力。
新增 CI 使用普通／TSan 正负测试并保留失败证据，不改变默认后端、安装或发布条件。

最终交接专项普通／ASan／TSan **各 176/0**，分别为
`build/rotation-handoff-tests.TxAsZN/`、`4hJYRw/`、`apcGmZ/`。
四个撤销保护的单变量负控在三种模式均按预期退出 1，对应 **4／10／2／48 个失败**，
不能把 crash、编译失败或看门狗终止当作有效负控。输入源码稳定性校验通过，生成源码
单独记录 SHA；root 复核正负结果和 sanitizer 日志没有新增异常。未改变各用例期限。
helper 最终普通／ASan／TSan 各 **50,051/0**（包含 50,000 次固定混合输入压力迭代，
不是五万个不同功能），保留原 coordinator **77/0** 与 ownership **4/0**；两负控各有
一项明确失败、退出 1。证据 `build/rotation-intent-tests.rNicH0/`、`snTVEp/`、`lFND5E/`。
失败退出采证另验证非法模式仍退出 2；受控 runner 在首次生成源码后退出 7，仍保留原
退出码、输入校验和生成 manifest，未把采证成功冒充测试成功。

冻结源码下的旧功能回归：ControlledCore **41/0**＋两有效负控、Lifecycle **76/0**
（含 ASan／旧系统 typecheck）、SeekTiming **37/0**、Navigation **317/0**、Live build-only；
NativeClip **235/0**、A/B **151/0**、Route **287/0**；原 VideoTools 英文 **942/0**、
coordinator **77/0**、task manager **132/0**；旧 viewport 中英各 **1098/0**、新 viewport
**172/0**。stale compatibility 与 viewport route 单变量负控分别在 **235 项中失败 5 项**、
**172 项中失败 7 项**，均退出 1。原断言未删除；fixture 仅新增实际调用的接口与明确边界，MPV-only 路径不
伪造 native 成功。日志和五个生产文件前后稳定 hash 位于
`build/rotation-legacy-final.vg4hNP/`；本轮 Live 只是编译，不冒充新增的实播结果。

## URL 加入列表的交接所有权（仍非完整 App URL 验收）

只改 `chengying://open?url=...&enqueue=1` 的加入列表入口。此前 native `info.playlist`
有一项，但实际追加发往尚未加载媒体的 MPV；切换期间列表暂空时，连续请求又可能误入
新开片分支。现在 native 请求先取得同文件兼容交接，恢复准确位置后顺序追加。普通
`appendToPlaylist`／`addToPlaylist` 及后台同目录匹配的同步锁和入口不变。

一个 batch 至多保存 64 个请求、256 条路径与 1 MiB UTF-8 路径；超限拒绝新请求，不挤掉
已接受项。capture、retire、load、restore 期间只建一个交接，保留 volume／rate／A-B／
viewport，并接收最后的 pause／seek 意图。15 秒 watchdog 只取消所属动作；同文件仍可
恢复播放，用户开新文件、同路径重开、停止、退出或加载失败则取消整个所属状态。
不同 capture 的迟到回调不会清除新 batch；其他兼容动作不能抢走已有 enqueue continuation。

实际 MPV 命令返回值决定成功数量，不因调用过 helper 就提示成功。所有追加先于任意
completion；逐个回调和最终 main-queue OSD 都检查媒体 receipt，通知同步重开文件、后续
MPV file-start（含同路径）不会把旧成功提示发到新画面。restore-only 状态也保持加入列表
入口，避免动作超时后空列表又误开片。native enqueue 的混合 `new_window`／全屏／PiP／
`mpv_*` 参数在分配新 core 或开图片前明确拒绝；没有假装这些额外选项已迁移。

冻结生产 Core SHA-256 `d42407567af7382b895d8280d4e3cc2e2a063e0aa10cb0deda37b4d2204dd16f`，
AppDelegate `0bb812b752409373e388a72264c31f612ae0bdf11ba7d640fb363b9f85038930`。
`Tools/URLPlaylistEnqueueTests` 机械抽取真实 Core 方法、AppDelegate enqueue 分支及
`sendOSD` 最后的异步 closure；capture／shutdown／MPV 服务和早期 UI 门禁是显式受控边界。
不读取用户媒体，不发送系统 AppleEvent，不创建 App 或窗口；不能说完整 App URL 交付通过。

普通／ASan／TSan 各 **118/0**，八个单变量负控分别产生 **27／9／7／2／3／4／2／2**
项预期失败并退出 1；超时、编译失败或 sanitizer 告警不能冒充有效负控。证据为
`build/url-enqueue-tests.ZetQ3f/`、`1fdLoF/`、`X1m0YH/`，输入稳定性检查均通过。
runner 随后增加明确拒绝 sanitizer 诊断，不改生产和断言；主代理以最终 runner 独立复跑
普通 `oLU53f`、ASan `eHhRop` 和 TSan `kA0o72`，同样全部通过、source-check 为零。
新 CI 分开运行普通与 TSan 并保留正负日志／源码 hash，不改默认准入或发布条件。

旧 fixture 只增加明确的无 enqueue 边界或复用真实 enqueue 代码／受控服务，未删除旧断言
或延长 deadline。同 Core／AppDelegate 的 Core 41、Lifecycle 76、Seek 37、rotation 三模式
176 及四负控、旧工具英文 942、task manager 132、旧 viewport 中英各 1098 通过；真实旧
MPV 剪辑预览 324 项通过，实际收到 308 个 rendered frame，清理成功。
证据汇总 `build/url-enqueue-legacy-verification.6CsPhO/`。
Route 首轮 287 项虽通过，但 CYN 同时开发使 source-check 失败（`SNvZHM`），不能算同源
成功。CYN 暂冻于 `413c4afa` 后另跑 Route `wookuc` 287、Clip `vPbsSc` 235、A/B `wkFaRV`
151 全部通过且输入 hash 稳定；这是该时点 decoder 的旧功能回归，不能替代尚在实现中的
最终 AV1 decoder 验收。上述所有检查也不替代整窗 URL 事件交接。

## 后续 CI 工具修复与准入偏好一致性

冻结 `f36429bf` 的开发 CI `38324899462` 已完成且失败：media-helper job 和正式 App 构建
通过，但 rotation runner 在首个有效负控后调用 runner 未安装的 `rg`，以 **127** 退出。
这是检查脚本错误，不是负控验收通过。完整 App 测试随后尝试构建，但新增预览诊断把
生产的 `MainWindowController!` 存成推断的 optional 局部变量并直接访问成员，编译失败。
该 run **没有启动 92 项测试 App**，不能报 92 项通过；测试 workspace 清理已完成。
原产物保留在 `build/native-app-ci-38324899462.M8y7Ko/` 和
`build/native-rotation-ci-38324899462.mBveLA/`。

两 rotation runner 和后续 URL runner 改用系统 `/usr/bin/grep`，断言和期限不变。
无 `rg` 的系统 PATH 下，rotation intent 普通／TSan 各 50,051、77、ownership 4 通过，
两个负控各一项失败；handoff 普通／TSan 各 176 通过，四负控仍为 4／10／2／48 项失败。
证据 `SlYYLF`／`MB3EFx` 与 `ghQd26`／`gP68Dw`。同一原 CI 负控 log 的 matcher 检查
`build/rotation-ci-path-diagnostics.RIVy9z/` 中，旧 matcher 127、新 matcher 0、缺少目标
断言时新 matcher 1；没有把任意非零都当合格负控。URL 最终系统 PATH 复跑 `cYhHsG`
保持 118 项与八负控，通过 source-check。

诊断代码现在显式 unwrap，准备测试的声明边界改为与生产一致的 IUO，并加入只撤销
unwrap 的编译负控。`python3 -B Tools/NativeAppTests/test_runner.py` **32 项通过**，
macOS 12 typecheck 必须拒绝旧 optional 访问；原 92 项 runtime 标签和 110／150 秒期限
未改。证据 `build/native-app-preparation-optional.6WpcvU/`，driver SHA-256 为
`6b6bb5c54573c36bb4f4e5091efb98e053b073f421611086ea5de7c85f0812a4`。
这是测试构建准备，不是整窗通过。

另确认关闭“自动加入同目录文件”仍被 sibling gate 过度回退。生产只改一行：目录枚举
取 `shouldAutoLoadFiles && playlistAutoAdd` 的开始时快照，与原 AutoFileMatcher 行为一致。
字幕、HDR、多文件及 used-MPV 门禁仍保留。冻结 Core `e1cd71918d1f5c0f3aa0954ab9e0130bbd35ab23068a9db8fcb9741db4b193d5`；
`Tools/NativePlaybackAdmissionTests` 抽取完整准入函数，在真实合成 MP4／字幕／子目录运行
生产枚举，startup 和 transport 是明确 recording boundary。普通／ASan／TSan 各 **64/0**，
只移除此偏好条件的负控各 **64/3**，精确失败集合与退出码均符合要求；系统 PATH 下无
`rg` 依赖。证据 `b6ZTTu`／`cqCUw2`／`p5KHQ4`，主代理最终独立复跑 `xacTpY` 同样通过。
原 Route 287 项仅补偏好声明，未改断言；`dylqWt` 同源通过。新切片是准入偏好修补，
不是原生队列实现，也未放开默认路径。

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
  本阶段早期审计确认，当时的播放 FFmpeg 7.1.5 不含 AV1 VideoToolbox backport，
  `CYNMediaDecoder` 按 codec ID 选择到的是 libdav1d，不能把当时的缺口仅描述成缺 M4 测试。
  后续已补库、明确 decoder 选择与初始化软件回退，见本文前部的 AV1 后续切片；
  仍没有目标 M4 的实际硬件输出证据，不把新增源码或 M2 软退写成硬解验收。
- 旋转、SAR 和画面缩放／平移已接入新 surface；完整 App 组合验收仍未完成。
  完整字幕／轨道选择、截图、帧进、HDR 用户开关及播放列表策略仍走兼容路径。
  剪辑预览恢复已接入原生路径，冻结 0455ab7c 的完整 App 自动预览／连续编辑／停止／
  关窗取消已通过；后续交接修补仍需新的同源整窗回归。
- 倍速当前只承诺 0.5–2.0；不能直接取代旧界面更广的速率范围而不给用户提示。
- 暂未测得相对旧内核／Movist 的耗电、CPU、总内存、丢帧或启动速度优势。

## 下一阶段接入清单

1. 已有 `PlayerCore` 开片、transport、音量、单文件循环、A/B 和异步关闭分派；冻结
   0455ab7c 的完整 App 92／54 首次通过。后续窗口与附件修补需再做同源回归，且不能
   把一次短片整窗成功当作全部媒体或长时播放验收。
2. 已隔离 `VideoView` 的 GL 假定并迁入图层几何与 viewport；继续验证全屏／跨屏／真实
   HDR 色彩，补已加载 native→MPV 的整窗状态交接，不直接放开现有准入保护。
3. 快捷键已迁入速度、A/B、viewport；其余旧 mpv 透传仍明确兼容，继续补齐截图、帧进、
   音轨等能力。日常同文件夹多媒体／播放列表及已用 MPV core 的 native 再进入仍待设计验证。
4. `VideoToolsPlayerBridge` 与预览 snapshot/restore/onUnload 已接入原生异步状态；
   冻结 0455ab7c 已实际验证重复编辑 A/B、切片预览、快速换片和关闭，保留该组回归。
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

### 新 AV1 backport 依赖的独立 4K 回归

上述十分钟结果不能代替后续 decoder 变更验证。最新冻结 CYN `e3bcc18e`、session
`5542c267`、隔离新库 `build/native-av1-playback.7FMHum`（avcodec `a183c820`）
重新执行原 180 秒断言，292/0，实际 182.55 秒；证据 `native-playback-soak.iX9p53`。
原错参考负控 `DOJ5cD` 准确在首次像素比较失败，16/1、退出 1，随后异步清理通过。
两轮 14 个 source/tool 输入、156 条完整依赖记录、6 个生成物前后 SHA 全通过；
runner `4ee0aaad` 可选 `NATIVE_PLAYBACK_DEPS`，不覆盖旧库，失败退出也校验身份。
编译／实际运行／tee／校验的退出码和日志分开保留，不将负控失败写成正向通过。

三轮颜色／尺寸／位深检查均通过，未知颜色为零，无图观察为 4／6／3；未测其持续时间。
样本预算峰值 124,623,360 字节；RSS 260,276,224、footprint 166,462,400 字节，后两轮
关闭后差值 −573,440／−40,615,960 字节。这是本次静音 CLI AppKit 测试，不是复杂
电影、听觉／A-V drift、整 App、AV1、实体 HDR 或目标 M4 验收。完整说明见
[压力验证 README](../../Tools/NativePlaybackSoakTests/README.md)。

### EOF 变速修补后的同源 4K 回归

主代理用 session `aab38cba`、CYN `e3bcc18e` 和同一隔离 `7FMHum` 依赖再次执行
原 180 秒命令，`native-playback-soak.85CsqG` 为 292/0，182.22 秒；原错参考
`tYX5s4` 为 16/1，准确只在首次 H.264 像素比较失败，随后正常关闭与释放。
正负源／依赖清单一致，source/generated/dependency 前后身份通过；正向所有退出码
为 0，负控 playback/runner 为 1，identity/tee 为 0。无任何生产或测试断言变更。

三轮都显示全部四个正确源区间，尺寸、位深、颜色异常为零；无图观察为 4／2／5，
未测持续时间与成因。样本预算峰值 124,623,360 字节，RSS／footprint 峰值分别
261,242,880／180,208,624 字节，后两轮关闭后差值 +4,472,832／−42,270,744 字节。
三次 retired session 均释放；这仍是静音合成短素材实际显示缓冲验证，不是零泄漏、
无卡顿、实体 HDR／音频、AV1 硬解或完整 App 通过声明。
