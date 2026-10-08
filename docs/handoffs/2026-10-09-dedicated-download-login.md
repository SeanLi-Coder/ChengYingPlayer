# 独立下载登录与升级后权限体验

基线：`7e509959`（上一正式版 `v0.2.69` / build `80` 后的文档提交）。
候选：`v0.2.70` / build `81`，提交 `2e069c40` 已进入主线，发布被实播回归拦截。
本轮唯一发布者为 Codex；没有正式发布，最新公开版仍为 `v0.2.69`。

## 用户需求与实现

用户接受专用登录方案，目的为停止默认依赖日常 Chrome 的受保护资料，
不是授权修改 TCC、自动点系统权限或跳过网站登录。

- 下载中心新增六平台独立登录面板，首次手动登录后显式保存。
- 默认 `dedicated`；旧 Chrome、匿名公开模式均需用户明确选择并保存。
- 登录方式、专用 Chrome profile 和不可变 Cookie 修订位于已有 DownloadCenter
  Application Support 数据目录，App 更新不搬动、不覆盖。旧偏好与任务不迁移。
- 每个新任务绑定该平台当时的修订；旧任务重试不更换身份。登录更新后明确要求新建任务。
- 保存／读取检查平台认证 Cookie 的域、根路径、非空及过期时间，统计 Cookie 不能冒充登录。
  这是本地启发式，不代表网站已认可登录；账号被服务器撤销仍需要实站响应确认。
- Cookie 仅导出允许平台域，分区 Cookie 不扁平化；文件／目录 0600／0700，
  无跟随链接读取、限制大小、拒绝重复 JSON 字段，快照原子写且旧修订不覆盖。
- pinned yt-dlp 所有提取入口、XHS 预检及总结音频／字幕复用专用资料，禁止匿名回退。
  修复 CookieJar 复制导致 host-only 策略丢失，验证真实 requests 请求头和重定向。
- 专用窗口沿用保存的代理，无隐式直连重试；打开／保存／关闭期间阻止代理更换与更新安装。
  关闭未确认不会发成功状态，也不会解除 watchdog；不会终止日常 Chrome。
- API／任务响应不含 Cookie、账号、路径或专用修订标识；保留固定诊断码供反馈。

## 已验证与边界

- 上游隔离回归：1,405 项通过；原始 69 文件的来源哈希未改。
- 原生 WKWebView：中英文各 323 项通过，另 3 个 runner 测试通过。
- 真实隔离 Chrome UI：32 项通过，使用实际下载器 HTML/app.js 和本地 API fixture。
- 下载模块完整回归：1,373 项通过、65 个 subtests 通过，无跳过；包含独立存储、认证接入、API、总结与真实隔离 Chrome UI。
- 独立安全复核通过：总结的两条请求路径均保留 host-only Cookie 策略；关闭失败不解除 watchdog；旧任务不换身份。
- source helper 协议／私有 API／重启 smoke 通过。新增冻结自检验收和实际更新保留
  专用登录配置、快照、浏览器会话合成文件的检查。本机六种真实签名安装场景通过：完整包、增量包、损坏完整包拒绝、损坏增量回退、不匹配增量回退、双重损坏拒绝。
  成功路径均完成实际替换和重启；使用本地 Sparkle SDK 的隔离 App fixture，不冒充最终发布 App 的 CI 验收。
- `ruff check`、`git diff --check`、vendor 完整性与 `typos==1.50.2` 均通过；发布策略 19 项、公开验收工具 10 项通过。
- 所有测试使用合成资料，没有读取用户日常 Chrome、钥匙串、真实 Cookie 或测试其他账号。
  没有向真实网站登录；六平台入口已接入不等于六平台真实账号验收。
- Google 可能拒绝自动化控制的专用 Chrome 登录，界面明确告知，保留显式旧模式或匿名模式。
- 认证 Cookie 格式可变化，未知格式会停止而非猜测。现有 Qwen Instagram 站点适配清单未接管。
- 关闭异常时只能报告未确认并保持屏障；未证明所有异常下浏览器进程均能自动清理，
  界面提示只手动关闭专用窗口后重开播放器，不要求强制结束日常 Chrome。

### 本机复核命令

```sh
CHENGYING_REQUIRE_CHROME_UI=1 build/player-v29-tests.nD75s9/bin/python -m pytest -q -rs Tools/DownloaderHelper/tests
build/player-v29-tests.nD75s9/bin/python -m ruff check Tools/DownloaderHelper --exclude vendor
build/player-v29-tests.nD75s9/bin/python Tools/DownloaderHelper/verify_vendor.py
build/player-v29-tests.nD75s9/bin/python -B Tools/SparkleUpdateTests/test_public_workspace.py
build/player-v29-tests.nD75s9/bin/python -B Tools/SparkleUpdateTests/test_release_policy.py
SPARKLE_TEST_ROOT=build/sparkle-local-updater.tmslcJ/sdk build/player-v29-tests.nD75s9/bin/python -B Tools/AppUpdateIntegrationTests/run.py --scenario upgrade
SPARKLE_TEST_ROOT=build/sparkle-local-updater.tmslcJ/sdk build/player-v29-tests.nD75s9/bin/python -B Tools/AppUpdateIntegrationTests/run.py --scenario delta-upgrade
SPARKLE_TEST_ROOT=build/sparkle-local-updater.tmslcJ/sdk build/player-v29-tests.nD75s9/bin/python -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-dmg
SPARKLE_TEST_ROOT=build/sparkle-local-updater.tmslcJ/sdk build/player-v29-tests.nD75s9/bin/python -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-delta
SPARKLE_TEST_ROOT=build/sparkle-local-updater.tmslcJ/sdk build/player-v29-tests.nD75s9/bin/python -B Tools/AppUpdateIntegrationTests/run.py --scenario mismatched-delta
SPARKLE_TEST_ROOT=build/sparkle-local-updater.tmslcJ/sdk build/player-v29-tests.nD75s9/bin/python -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-delta-and-dmg
```

## 发布记录

尚未发布。必须完成完整回归、冻结 helper、DMG／更新签名、实际更新保留测试和匿名交付核验后更新此节。

### 候选首轮与渲染测试对照

候选提交 `2e069c409e5c1e13dc1ed1bd544fbd2bd5d94567`，标签 `v0.2.70` / build `81`。
流水线 `37815780691` 的首轮：媒体／下载测试 job `113443922406` 成功，
构建 job `113443921936` 在既有 4K 关闭／重开渲染测试失败；没有上传发行资产，
发布 job `113457285945` 跳过。此前已完成内置工具冻结构建及其自检。

- 失败发生在第 0 次首次播放、执行关闭之前：加载和播放推进正常，`frames=4`、
  `pictures=0`、`position=2.3`、等待 `8.010s`。原“两张实际彩色图片”断言有效拦截。
- 本机原样命令也复现一次：`frames=7`、`pictures=0`、`position=7.6`、等待 `8.005s`。
  临时有界诊断发现真实 FBO 非零且完整、上下文正确、没有 GL 错误，但采样全黑。
  不能归因于零 FBO；成功诊断前后 viewport 都为 `640×360`，也没有尺寸越界证据。
- 随后的诊断、关闭诊断和精确旧观察器对照三轮各完成 `30` 次加载／关闭，
  `rendered=61`、`pictures=61`。未遮挡标记为 false、App 未激活也能成功出图，
  不把遮挡当作已确认根因。所有测试工作区正常注销和清理。
- 完全撤销临时诊断、恢复原文件及编译顺序后，原命令再次在首次播放失败：
  `frames=7`、`pictures=0`、`position=7.5833`、等待 `8.004s`。
  因而不能把诊断版本的通过当作原测试已稳定通过，更不能当作修复证据。
- 单次最小日志实验仅增加有界 mpv 警告／错误输出及 CGL 初始化上下文比较，
  保持原编译顺序、采样和断言；完成 `30/61/61`。只有预期软件渲染器警告，
  首八次 draw 的初始化／回调／当前上下文相同，没有 shader 错误。
  这次没有复现失败，故不能排除失败运行中的上下文问题，也不能认定日志改变修复了问题。
  所有临时诊断均精确撤销，`git diff --exit-code -- Tools/PlayerCloseTests` 为空。
- 该目录、生产 `ViewLayer`、锁与依赖选择、CI 工作流相对 `v0.2.69` 完全未改。
  现有证据支持间歇性现象，但不足以确定根因，不能宣称生产黑屏或测试本身已修复。
- 仅对相同候选提交重跑一次失败构建 job；保持原始测试和全部断言不变，
  没有跳过或放宽超时。如果第二次仍失败，不能继续重复试绿作为发布依据。
- 第二次构建 job `113461595044` 已在同一门失败：首次播放 `frames=4`、
  `pictures=0`、`position=2.9833`、等待 `8.013s`，测试工作区正常清理。
  发布再次跳过；没有第三次原样重试，没有发布 `v0.2.70`。
- 本机单变量补充 `NSApplication.shared.finishLaunching()` 仍在首次播放失败：
  `frames=7`、`pictures=0`、`position=7.6`、等待 `8.000s`。
  该诊断改动已撤销，不能把启动完成步骤遗漏宣称为此次黑帧根因。
- 延后到 READY 才输出的有界诊断明确再次复现失败：七次完成绘制的初始化／回调／
  当前 context 一致，入口／出口 viewport 均为 `[0,0,640,360]`，读写 FBO 一致且完整，
  颜色掩码全开、scissor 关闭、无 draw 重入，63 个 RGBA 样本全黑且 GL error 为零。
  因而这次失败不是上述几项采样假阴性。增加 NEXT_FRAME_INFO 和更多 GL 查询的下一次
  诊断则完成 `30/61/61`，只能记录为通过的诊断运行，不能当作生产修复。
- 固定诊断矩阵只编译一次，二进制 SHA-256 为
  `d2243d2f9a148b8e5e947a95fb6a296e5a1689c8383b2b99ba6957524c0a9fdb`。
  原诊断／仅 NEXT_FRAME_INFO／仅扩展 GL 查询／两者／原诊断的固定顺序结果为
  `PASS / PASS / FAIL / FAIL / PASS`；成功项各完成 `30/61/61`，失败项仍在首轮全黑。
  两者模式失败时七条 NEXT_FRAME_INFO 全部返回成功、flags 均为 1，depth、stencil、
  cull、blend、rasterizer discard、sRGB 全关闭；其余 context／viewport／FBO 正常。
  不把查询相关性认定为根因，更不以加入查询代替修复。汇总没有保留 target_time，
  不补猜这项数据。合成结果保留于本机 `build/player-close-diagnostic-matrix-20261009.json`。
- 最后单次完成性诊断只在原九点全黑时才会 `glFinish` 并重读，二次结果不参与原通过断言。
  该次完成 `30/61/61`，未遇原始黑帧，因而 `glFinish` 从未执行；同步假设仍未验证。
  完整合成记录见本机 `build/player-close-completion-diagnostic-20261009.json`。
  其后用 `apply_patch` 撤销全部临时测试改动，`git diff --exit-code HEAD -- Tools/PlayerCloseTests`
  为空。没有将诊断查询、固定延迟、放宽断言或跳过检查作为发布修复。

### 当前交付状态与后续入口

- 独立登录功能代码和上述功能回归已完成，但本轮正式发布未完成。核实远端 latest 仍为
  `v0.2.69`；没有覆盖用户安装、偏好、模型、Chrome 资料或系统权限。
- 渲染检查失败发生于测试 fixture 的首次软件 OpenGL 播放。尚未确定是测试环境／观察器
  还是生产路径问题，不能宣称只是误报，也不能外推为所有实际硬件播放均黑屏。
- 后续应先保留原始命令复现，找出可解释失败且能验证的最小修补；不要恢复临时诊断后
  仅凭一次通过就发布。修补必须保留真实彩色图片、播放推进和 30 次关闭／重开检查。
- 不移动 `v0.2.70` 标签。若需要代码或测试修补，使用更高版本／build 作为新候选，
  完成完整构建、冻结 helper、签名、实际更新保留及公开更新交付核验后才能正式发布。

### 后续定位：缩放 LUT 未初始化（2026-10-09）

- 两次 CI 拦截仍是同一个首次 4K 实播黑帧断言，不是独立登录功能测试失败。
  没有第三次原样重试，也没有修改已发布版本或 `v0.2.70` 标签。
- 本机进一步按实际 GL draw pass 读取浮点画面，固定三次结果为
  `PASS / FAIL / FAIL`。失败时前两个 pass 的九点输出与成功项逐项相同，
  第三个色度横向 Lanczos pass 的 UV 为 NaN，GL error 仍为零。
  CPU 解码截图正常；GPU 截图在两个失败进程中分别全黑、严重缺色。
  不能将其解释为仅观察器误报，也不能外推为所有硬件播放都会失败。
- 后续增加 uniform、LUT 和邻点读取的固定三次均通过，不能当成修复。
  有效六个系数完全相同，两个 padding 槽却出现不同垃圾值，说明输入确有
  未初始化数据。报告分别在本机 `build/player-close-glpasses-20261009` 和
  `build/player-close-gluniforms-20261009`；只含生成素材和隔离测试资料。
- **证据范围修正：**上述本机实验使用的库 SHA-256 为
  `5a76b8188eecf781a22567f6902f67e8da82da99495e633da1aa2d3edd65e81e`，
  本机 build record 只有两个 ICC 补丁，并非 CI 的完整四补丁链。它证明本机
  渲染故障机制，不能冒充相同 CI 二进制复现。后续验证必须显式选择重新构建的
  完整补丁库，并记录库摘要和补丁清单；不依赖旧 `deps` 目录的新旧程度猜测身份。
- mpv 上游已于 2026-09-29 修复同一处未初始化：
  [72d43dc9](https://github.com/mpv-player/mpv/commit/72d43dc9c999a21d867cdc0f934f3e4cd2195aa9)，
  [PR 18540](https://github.com/mpv-player/mpv/pull/18540)。当前回移完整六行补丁，
  只填充每行最后两项，不改变有效系数、滤波器、HDR、码流或 libmpv ABI。
  五补丁链零 fuzz 应用及全部九个修改源码校验通过。
- `python3 -B other/patches/test_scaler_lut.py`：实际 mpv 权重生成代码的旧逻辑
  保留 512 个异常 padding 值；补丁的 444 组 kernel/size/NaN/Inf 回归在
  ASan/UBSan 下通过，系数与内存边界不变。
- `python3 -B Tools/ScalerLUTTests/run.py`：独立真实 Apple Software Renderer
  4.1 APPLE-23.1.1 因果实验通过。相同 context、RGBA32F LUT 和有效系数下，
  只改变 padding：NaN、正负 Inf 在 LINEAR 采样中污染 24 个有效系数通道，
  NEAREST 对照正常；应用从实际补丁提取的循环后，四个相位的全部有效系数恢复。
  该实验不创建 App，不用个人素材，也不替代完整播放器和发行验证。
- 首轮故障诊断曾发生测试 App 注销失败，按安全规则保留工作区。确认进程退出后，
  对该 exact workspace 调用原注销函数一次，返回成功且 scoped registry 查询为空；
  未重置系统注册库、未删除安全标记或强制结束系统服务。
- 完整五补丁播放库已在 `build/scaler-lut-playback.uZAXpM` 隔离重建，
  libmpv SHA-256 为 `2bdcbd6e80d3dd383d1676be907920aa7fb41195d990fb0e5d13f7417a280c3b`。
  分发核验确认 16 份固定源码、五补丁链、九个 ARM64 动态库、原许可证及构建记录；
  PlaybackBuildTests 的 69 项实际选项和 11 个配置值通过。没有替换旧 `deps`。
- 新库软件 GL 固定三次均完成 `30/61/61`；随后不带任何诊断选项的原门禁再完成
  `30/61/61`。硬件单次完成 `30/150/150`，断言实际使用 `videotoolbox`。
  合计 150 次关闭／重开均通过，所有工作区正常清理。原 8 秒等待、真实画面、
  播放推进断言不变；没有用截图、重试、GL 状态干预或放宽采样作为通过依据。
- 新库 ICC 回归 6,158 项／12 次实际渲染通过；sRGB、PQ、HLG 渲染分别
  8,676／8,674／8,682 项通过，各五次真实出图。HDRSourceTests 的原版负例与
  修后 154 项合成 AVFrame 校验通过，未改变 Dolby Vision、色彩或 HDR 策略。
- **同构建四补丁负对照已复现：**仅撤回 LUT 六行修补并重编译，其他八个库和 145 份
  头文件逐字节相同。诊断库 `build/scaler-lut-negative.lQQZYg` 的 libmpv SHA-256 为
  `9b8687229c976d7721f15a7e2faebef2d88b4dedb81fc16c8e24ab08a1533fde`；
  它不是生产分发，未伪造五补丁 build record。固定三次为 `PASS / PASS / FAIL`，
  无追加重试，失败发生于首轮 `frames=7/pictures=0/wait=8.009s`，清理完成。
  同次读取的 LUT 有 214 个负 Inf，全部位于 stride=8 的第 6 号 padding 槽；
  前六个有效系数均有限且与成功项完全相同。实际 uniform 指向同一 LUT，
  第 2 个缩放 pass 即输出 NaN，随后传入下一 pass 并最终变黑。
  这次首坏 pass 为第 2 个，不沿用早期旧二补丁实验“第 3 个”的观察。
  证据在 `build/player-close-lut-negative-20261009`，合成诊断会改变时序，
  不冒称与 CI 完全相同二进制；但与独立 GL 毒化实验共同确认未初始化 LUT 的机制。
- 原始门禁保留，新增有界诊断只在明确选择时启用；多次诊断必须全部通过且清理成功
  才报告整体通过。加载库路径、SHA、补丁身份均记录，拒绝继承的 loader/MPE 覆盖。
  两位独立只读终审未发现发布阻断项。分发回归 32 项、源码下载 37 项、
  更新策略／交付／增量测试 19／20／14 项通过；模拟交付不冒充真实发布。
- 修补候选为 `v0.2.71` / build `82`。本地根因及回归已完成，仍需完整 CI、
  正式 App 更新安装、签名资产与匿名更新交付检查；目前不能写成正式发布成功。

### v0.2.71 发布验收（未发布）

- 候选提交 `af181278c50bf4d315bc2475472e2428d8dec846` 已推送，
  [标签流水线](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/37840583312)
  已执行检查。拼写检查 `37840581460` 已通过；同提交重复主线构建
  `37840581475` 已请求取消，以完整标签流水线为发布依据。
- 本机另用独立保存的 v0.2.47 可信公钥，对已有 v0.2.69 feed 和完整 DMG 先验签、
  后只读挂载；核验真实 v0.2.69 / build 80、ARM64、固定 Bundle ID、严格代码签名
  和不变更新公钥，再保存原始 `trusted-app-info.plist`。临时卷已正常卸载和清理。
  这只补齐后续 v0.2.71 验证的可信旧版本身份，不冒充匿名下载或增量还原测试。
- 本机匿名交付预检查：默认网络路由返回 GitHub API 限流；仅在检查进程中使用直连
  和已安装的 macOS 原生证书信任后，匿名 latest 成功返回 v0.2.69。
  没有关闭 TLS 校验、修改系统网络／信任或改变用户下载代理配置。
- 构建 job `113528622159` 的新五补丁播放库、CPU 回归、分发、ICC、HDR 及
  Dolby Vision 源码检查均通过，但于 UTC 20:46:48 在媒体源码下载失败。
  x264 原站只返回 7,439 字节，SHA 为 `9f2460ea87ecfbf40fff92608ef95867d485028e31ce4b5d56a270d4b4af278a`，
  不等于固定 `cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9`。
  校验正确拒绝；没有创建发行资产，未运行到该候选的关闭／重开门禁。
- 同一提交镜像
  `https://codeload.github.com/mirror/x264/tar.gz/b35605ace3ddf7c1a5d67a2eb553f034aef41d55`
  实取为 1,040,327 字节，SHA 与原锁一致，`cmp` 与已有原站缓存完全相等。
  270 个普通文件、19 个目录及顺序、内容、权限、时间、PAX 等元数据全部一致；
  v0.2.69 合规源码包中的原归档也再次核对为相同 SHA。
  因此只将固定主入口切到该镜像，并限定传输时长；不在坏 SHA 后静默容错，
  不改变版本、commit、文件名、源码或固定 SHA。原站本机此时能够返回正确包，
  不能据此认定 CI 出口已经恢复，故不原样重试这次构建。
- 下一候选使用 `v0.2.72` / build `83`，重新完成完整检查，不移动旧标签。
- 下载入口回归共 43 项通过，覆盖固定五字段身份、缓存不触网、HTTPS／时限、
  成功 HTTP 的错误 SHA 拒绝、十类传输失败的普通及条件调用、仅清理自身部分文件。
  Shell 语法与 diff 检查通过，并经另一位协作者独立复审。更新身份策略 19 项再次通过。
