# 澄影视界（ChengYing View）

<p align="center">
  <img src="Brand/ChengYingIconMaster.png" width="180" alt="ChengYingPlayer icon">
</p>

一款面向 macOS 的中文视频与图片查看器，兼顾日常播放、图片缩放与动图、图片格式转换、轻量视频处理、本地 AI 中文字幕与原画质素材下载。处理在本机完成，不包含 AI 超分或云端转码。应用显示名称已更新，原有 bundle id、设置、数据目录、CLI 和 GitHub 仓库地址保持兼容。

原生界面采用石墨色与冰蓝点缀，提供深浅两套外观：欢迎页集中呈现打开文件、继续上次与最近播放；工具面板按操作分组，并将主要导出按钮固定在底部；AI 字幕的生成、模型和任务状态以独立卡片呈现。播放器时间轴与侧栏采用统一的强调色，保留原有快捷键和无障碍操作，不添加影响观影的装饰动画。

界面保留本地播放、视频处理和独立下载中心需要的入口：不提供网络地址直接播放、在线字幕搜索、插件、浏览器扩展和开发调试菜单。字幕加载、播放列表、章节、画中画、播放历史和快捷键设置仍然保留；旧版本保存的插件工具栏按钮会自动隐藏，旧的在线字幕自动搜索和高级 mpv 配置不再执行。

### 精简的功能范围

- 不再提供音乐迷你模式或自动切换音乐窗口；音频文件仍可在主窗口正常播放。旧音乐模式快捷键与工具栏按钮不会重新启用该模式。
- 移除通用音视频滤镜编辑器、保存的滤镜预设与去台标入口；保留播放时的画面裁剪、翻转、去隔行与基本画面调整。
- 移除不可恢复的“永久删除源文件”快捷键命令，保留“移到废纸篓”和“在 Finder 中显示”。视频处理始终另存新文件。
- 设置中移除无实际作用的自动更新选项、“恢复隐藏提示”，以及 ReplayGain、手动解码线程、强制独显、实验音频驱动、音乐无缝播放、SPDIF 直通等高级项目；使用安全的自动/中立配置。旧偏好数据不会被删除，但不再影响这些已移除功能。
- 保留硬件解码、HDR、ICC 色彩管理、音频输出设备、字幕/音画同步、播放速度与 A/B 循环；设置搜索仅显示仍然可用的项目。

## 下载与安装

安装版在 [GitHub Releases](https://github.com/SeanLi-Coder/ChengYingPlayer/releases) 提供 `ChengYingPlayer-v<版本>-Apple-Silicon.dmg`，原生支持 Apple Silicon Mac，包括 **M4 Max MacBook Pro**。早期标有 Source Only 的版本仅有源码，不是安装包。

1. 下载后双击 DMG，把 **ChengYing** 拖到 **Applications（应用程序）**。
2. 拷贝完成后推出安装磁盘，从“应用程序”打开“澄影视界”。
3. 不需要 Homebrew、Python、FFmpeg 或 `start.command`；媒体工具和下载运行环境随 App 安装。AI 字幕的大模型仍在应用内按需下载，不塞进安装包。

当前安装版使用 ad-hoc 签名，**尚未经过 Apple Developer ID 签名与公证**。若系统阻止首次打开，在确认来源和校验文件后，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 前往“系统设置 → 隐私与安全性 → 仍要打开”。不需要关闭 Gatekeeper 或执行删除隔离属性的命令；这不是免安全确认的公证安装。

每个安装版 Release 同时提供 DMG 的 `.sha256` 校验文件、对应的 `Release-Source.tar.gz` 源码包及清单。普通使用只需 DMG。播放栈由固定版本源码构建，源码包保留同次构建记录与依赖源码；签名、架构、动态依赖、源码对应或实际 App 测试失败时不会发布。

请使用 **v0.2.13 或更新版本**。v0.2.12 在发布后的真实 Mac 下载复核中发现辅助程序签名加载问题，已标记为不建议安装的预发布版本。修正版为视频与字幕辅助程序分别嵌入必要的库加载权限，并在构建和 DMG 打包时逐个检查；保留 hardened runtime，不要求关闭 SIP、Gatekeeper 或修改系统安全设置。

## 核心功能

### 原生看图与格式转换

通过「打开文件」、Finder 双击、拖放、欢迎页最近文件或下载中心的「查看」打开图片。图片进入独立的原生窗口，不经过视频播放引擎；打开单张图片会列出同目录图片，显式多选保持选定顺序。混合文件夹的图片与视频分别进入各自窗口，GIF 不再混入视频播放列表。

- 缩放：工具栏放大 / 缩小、适应窗口、100%；触控板捏合、鼠标滚轮缩放、拖动画面、双击切换适应 / 原尺寸。100% 是一张图片像素对应一颗显示器物理像素，兼容 Retina。
- 浏览：打开单张图片后，右侧默认展示同目录图片列表、文件夹名称和图片总数；每行同时显示文件名、Finder 颜色标签 / 自定义标签、大小和日期。默认按名称排序，也可按大小、修改日期、创建日期升序 / 降序排列；重新激活窗口或点击「刷新」会更新目录与标签。
- 幻灯片：点击「播放幻灯片」或在画面上按 `S`，按当前列表顺序自动切图；默认每张 **5 秒**、循环播放，可取消循环以在末尾停止。直接输入秒数后回车，或用加减按钮 / 滑块调节 **0.5–120 秒**，播放中立即生效并记住设置；可点「全屏」观看。图片完成解码后才开始计时，动图仍独立播放；手动切图重新计时，最小化暂停、恢复后继续，转换图片时停止幻灯片。无法读取的图片会提示并跳过，整轮均失败则停止。
- 动图：GIF、APNG、animated WebP 可播放 / 暂停、逐帧查看；保留不同帧时长和有限 / 无限循环。TIFF / PDF 多页不会被误判为动画。动画按需后台解码，不一次把所有帧装入内存。
- 转换：JPEG、PNG、GIF、APNG、TIFF、BMP、HEIC、AVIF、WebP。界面只显示当前系统实际可用的编码器；WebP 使用内置的固定版本开源编码器。默认输出到原图同级目录，自动生成 `原名_converted.ext`，重名自动递增，不覆盖原文件。
- GIF / APNG / WebP 之间支持保留整段动画；转静态格式前明确确认仅导出当前帧。TIFF 支持保留多页。导出重新读取原始像素，不使用界面缩略图，保留方向和支持范围内的色彩配置。

| 格式范围 | 查看 / 转换边界 |
| --- | --- |
| JPEG、PNG、GIF、APNG、TIFF、BMP、HEIC | 常用查看及导出；HEIC 依赖 macOS 编码器 |
| WebP | macOS 11+ 原生查看及动图；内置 libwebp 静态 / 动画导出 |
| AVIF、JPEG XL | 查看依赖 macOS 版本；AVIF 仅在实际编码探针通过时开放导出，JXL 只读 |
| ICO、ICNS、PSD、TGA、EXR、JPEG 2000、相机 RAW | 使用系统解码器查看并转换到上面的导出格式；PSD 为合成图，RAW 依赖具体相机型号，不支持写回 RAW 或保留图层 |
| SVG、PDF | 纯本地安全 SVG 与 PDF 多页栅格化查看 / 导出；SVG 使用固有尺寸，PDF 固定 144 dpi；不保留矢量编辑结构 |

**格式互转不等于任何格式都无损。** JPEG / HEIC / AVIF 使用高质量有损编码；GIF 受 256 色限制；JPEG / BMP 不支持透明度，透明部分转为白底；WebP 只支持 8 位。PNG / TIFF 尽量保留原位深和 ICC。HDR、色彩和半透明像素的最终结果受目标编码器限制，EXIF / GPS 私人元数据不会复制。SVG 不允许脚本、外部资源、DTD 或实体。不能解码的文件会明确报错，不以错误缩略图冒充成功。

看图实现采用 AppKit、ImageIO、Core Image、PDFKit，参考了 [FlowVision](https://github.com/netdcy/FlowVision) 的原生浏览思路；没有整体复制其他查看器，也没有引入其已停维护的 FFmpegKit。WebP 来源和许可证见 [图片编码器说明](Tools/ImageCodecHelper/README.md)。

除完整的本地音视频播放、字幕、播放列表、章节、画中画与播放历史外，澄影播放器提供四项视频处理工具、独立的 AI 中文字幕面板与下载中心，无需离开播放器：

在播放器菜单中打开 **视频 → 视频工具…**，或在播放器侧栏选择 **工具**。以下控制全部集成在 macOS 原生播放器内：

- 播放/暂停、前后跳转 5 秒、上一帧/下一帧，以及当前播放位置和视频总时长。
- 「放慢」「加快」按钮每次增减 0.1×，范围 0.1×–16×，也可从下拉菜单选择常用倍率；选择 1× 恢复正常速度。调速只改变播放与预览速度，导出仍保留原视频的时间和帧率。
- 播放或逐帧找到画面后，点「设为起点」「设为终点」直接打点；打点会暂停在当前画面，便于继续精确定位。
- 「定位起点」「定位终点」可返回边界画面查看；点「实时预览区间」循环预览所选片段。循环期间快进、后退、逐帧、拖动进度条与变速不会主动退出循环，跳转目标会限制在区间内。要定位到区间外，请先点「取消 A/B 循环」。

### 下载中心

从欢迎页点击「下载中心」，或打开 **文件 → 下载中心…**。界面在播放器自己的独立窗口内打开，不需要运行原项目的 `start.command`、启动 Terminal 或另开普通浏览器网页。为保留经过修复的完整交互，窗口内使用 WKWebView 承载原迹下载器的原有完整界面，并新增原生选文件夹和结果播放入口；登录或验证码仍在 Google Chrome 中进行。

- 完整收录 `rednote_downloader`（原迹下载器）**1.2.23 / e532e4f** 的下载引擎与界面，支持小红书、抖音、B站、YouTube 的主页、作品链接及原引擎支持的合集。保留视频、原图、图集和 Live Photo 的原有支持范围。
- 不设置清晰度上限，不重编码；继续使用原引擎的真实尺寸、时长、媒体 ID、作者归属和最高质量候选校验。不能证明身份或质量时会明确失败，不会用封面代替视频，也不会悄悄降到低清。
- 保留逐作品状态、下载速度、阶段提示、预计剩余时间、结构化错误原因与解决办法；保留取消、失败项重试、全部失败重试、重启后任务恢复和已经验证的下载结果。
- 默认保存到 `~/Downloads/ChengYing`，仍按作者和原来的命名规则整理；可用原生「选择文件夹」更改，再点击「保存设置」。下载完成的视频可直接点「播放」，图片可点「查看」，两者都可在 Finder 中显示。
- 「下载设置」下提供独立的「下载代理」：启用后填写 `socks5://127.0.0.1:7897`、`http://127.0.0.1:7897` 或 `https://代理主机:端口`，点击「保存代理」。可测试连接、关闭或清除，退出后会记住配置。这里的协议取决于代理服务本身：HTTP 代理也能连接 HTTPS 视频网站，不要仅因目标网站使用 HTTPS 就改写代理地址。
- 代理同时用于主页 / 单作品解析、浏览器辅助解析、媒体下载及后续重试；SOCKS5 使用远程 DNS。开启后若连接失败会报错，不会自动回退直连；关闭则明确直连，不继承系统或环境代理。只影响本 App，不改 macOS 或用户 Chrome 的设置。为避免进行中的任务中途换出口，保存变更前需等待所有解析、下载、后处理结束，或先取消任务。
- 「测试连接」会用输入或已保存的代理访问 YouTube 的 HTTPS 检查地址，不携带登录 Cookie、不保存输入；它只证明该 HTTPS 连接当时可用，不保证所有网站、地区、账号或下载权限都可用。HTTP / HTTPS 支持 ASCII 用户名密码认证；浏览器辅助解析不支持带认证的 SOCKS5，请改用代理软件的本地 HTTP 入口。HTTPS 代理必须使用受信任证书，不会自动忽略证书错误。
- 只使用可信代理。代理地址输入按密码遮挡，保存后不会回显凭据；留空保存会保留原地址和认证信息。「关闭」保留配置，「清除」删除保存的地址与认证。代理单独保存在下载中心数据目录的 `proxy.json`，文件权限为仅当前用户可读写，不会随任务记录、错误日志或项目源码公开。损坏的代理配置会阻止下载，需明确清除或修复，不能默默改走直连。
- 文件列表的展开、收起状态会在定时刷新和实时任务更新后保留，避免准备播放时列表突然折叠。
- 关闭下载中心窗口后，后台任务继续运行；退出播放器会停止任务，已下载文件保留。下次打开后，可按原界面的提示继续或重试，不会自动无提示启动旧任务。
- Chrome Cookie 默认开启，保留账号绑定和显式匿名模式，不会因账号读取失败静默改成匿名请求。首次读取 Chrome 登录态可能触发 macOS 钥匙串授权；只应下载自己有权访问和保存的内容。

下载中心当前固定为 **Apple Silicon、macOS 13.5 或更新系统**。Python、Playwright 驱动、yt-dlp、Node 和媒体工具由构建流程打包，不要求最终用户安装开发环境；**Google Chrome 仍需用户安装并登录**，播放器内的网页不是 Chrome 登录环境。该模块不会提高其他本地播放功能的最低系统要求。站点的限流、登录、地区、内容权限和临时接口变更仍可能阻止下载；这里不是绕过网站限制的服务，也不新增直播或 DRM 内容支持。

任务和设置独立保存在 `~/Library/Application Support/io.github.SeanLi-Coder.ChengYingPlayer/DownloadCenter`。不会自动读取、迁移或修改原 `rednote_downloader` 项目的任务目录；不会把 Cookie、浏览器用户数据、下载文件或个人配置打包进应用源码。内置服务仅监听随机本机端口，页面、API、静态资源和实时事件流均需要每次启动的新会话凭据，拒绝外部网页跨来源访问。

完整源码、来源哈希及迁移补丁说明见 [`Tools/DownloaderHelper/UPSTREAM.md`](Tools/DownloaderHelper/UPSTREAM.md)。原有回归测试与新增的会话隔离、原生桥接、代理配置 / 真实本地代理传输、冻结打包和退出测试在 CI 中运行；离线测试通过不等于所有网站、账号和网络环境都已实时实测成功。

### 文件夹视频列表与 Finder 标签

打开一个本地视频后，默认将同文件夹的其他视频加入右侧播放列表，按名称自然升序排列（例如 `2.mp4` 在 `10.mp4` 前面）；不会混入音频、字幕、隐藏文件或子文件夹内容。显式多选文件和导入播放列表保持原有顺序；已关闭自动加入同目录文件的用户设置仍然有效。

列表中的第二行显示文件在 Finder 中设置的颜色标签与自定义名称，支持多标签；空间不足时显示省略和数量，悬停可查看全部标签。打开侧栏、重新激活应用时会后台刷新，也可点击排序栏右侧刷新按钮。读取失败或文件已移走时不会阻止播放，不会修改视频或 Finder 标签。

列表上方可以选择「名称」「文件大小」「修改日期」「创建日期」，旁边箭头切换升序/降序；未知大小或日期的文件始终排在后面。排序调整实际播放队列，不重新打开视频，保留播放位置、暂停状态和 A/B 循环。手动拖动或随机播放后显示「手动顺序」，不会被后台刷新强行排回去。

### 固定快捷键

焦点在播放器中、没有输入文字或打开对话框时：

| 快捷键 | 功能 |
| --- | --- |
| 左 Command + Shift + L | 累计向左永久旋转 90° |
| 左 Command + Shift + R | 累计向右永久旋转 90° |
| `C`（不按 Shift） | 每次加速 0.1×：1 → 1.1 → 1.2 |
| `X`（不按 Shift） | 每次减速 0.1×：1 → 0.9 → 0.8 |
| `[` | 将当前画面设为 A 起点，清除旧 B 点 |
| `]` | 将当前画面设为 B 终点，回到 A 并启用区间循环 |
| `=` / `-` | 在当前视频窗口内放大 / 缩小画面，每次增减 10 个百分点 |
| Command + Shift + ← / → / ↑ / ↓ | 将放大后的画面向对应方向平移 |
| Command + Shift + `0` | 恢复原始显示比例并居中 |

按 B 前必须先设 A，且 B 必须晚于 A；0 秒可以作为 A。循环与工具侧栏是否打开无关，暂停时设置 B 会保持暂停，按空格即可继续循环播放。关闭当前文件会清除循环。若异常素材经过多次精确定位仍无法回到区间，播放器会暂停并提示，避免继续越界播放。

左右 Command 会分别识别，右 Command 不触发永久旋转。长按旋转或打点键不会重复导出或反复改写边界；松开后再次按下才累计。上述固定键优先于旧的自定义键位配置。

画面缩放以视频刚打开时的正常适应窗口显示为 **100%**，范围 20%–800%；例如按两次 `=` 为 120%，再按一次 `-` 为 110%。`+`（Shift + `=`）和数字小键盘 `+/-` 也可使用。缩放和平移支持长按；平移每次约为原始显示宽 / 高的 5%，到画面边缘停止，缩回 100% 或以下自动居中。平移与复位支持左右两侧 Command。这些操作只改变窗口内的视频画面，不移动或缩放窗口，不改变播放速度、A/B 循环、原文件或导出规格；换片或重开同一视频后恢复 100% 并居中。输入文字、弹窗、菜单或裁剪交互期间不会抢占这些快捷键。

其他默认快捷键也保留：空格播放/暂停，左右方向键前后跳转 5 秒，Option + 左右方向键逐帧定位，Command + `[` / `]` 减半/加倍播放速度，Command + `\` 恢复正常速度。循环单文件改为 Option + Command + L，在 Finder 中显示文件改为 Option + Command + R。其他键位可以在设置中自定义。

### 4K 播放稳定性

- 后台时间轴缩略图在换片、重开同一文件、关闭窗口或退出时取消旧请求；过期的解码与磁盘读取结果不会写回新视频。保存缓存使用对应视频的结果快照，不会把两部视频的缩略图混写。
- 缩略图解码的失败和取消路径释放 FFmpeg / Core Graphics 资源，按当前帧尺寸处理动态分辨率，校验尺寸和缓存长度。损坏的缩略图缓存会失效并重新生成，不影响源视频。
- 修复显示缩放 / presentation layer 切换时 OpenGL 对象的引用生命周期，以及停止显示刷新时的锁顺序问题。这些保护不通过降低视频分辨率、码率或关闭硬件解码实现。
- 已核对当前播放依赖与上游的 [AV1 解码崩溃修复](https://github.com/iina/iina/releases/tag/v1.4.2-build164)、[大视频被误当封面读入内存的修复](https://github.com/iina/iina/pull/5818)。当前固定播放栈已包含这两类修复，不代表所有历史崩溃都属于同一原因。

仓库提供真实 libmpv + OpenGL 的 4K H.264 / HEVC Main10 持续播放检查，覆盖循环、跳转、变速、换片与内存趋势；默认 3 分钟，可显式延长到 4 小时。测试使用自行生成的素材，不读取个人视频。它与原生渲染生命周期回归互补，**不能代替所有编码、HDR 显示器或数小时完整 App 的实测，也不保证任何视频都不会崩溃**。如果实际使用仍闪退，保留对应时间的 macOS 崩溃报告和视频编码信息，便于定位到具体调用栈。

### 视频与图片详细参数

打开本地视频或图片后，选择 **文件 → 媒体信息…** 或按 **⌘I**；图片窗口顶部和视频工具顶部也有「信息」按钮。独立信息窗口支持选中文字、复制全部、刷新，切换文件后同步更新，不会把旧文件的后台读取结果显示在新文件上。

- **视频**：封装格式、时长、精确文件大小、各视频／音频／字幕轨的编码、原始尺寸、旋转元数据、平均与标称帧率、码率、像素格式、位深、色彩范围／原色／传递函数、HDR 标记，以及音频采样率、声道等。
- **图片**：实际识别的格式、原始像素与方向修正后的尺寸、位深、透明通道、色彩与 ICC 配置名称、DPI；动图的帧数、明确记录的单轮时长和循环信息，以及可用的相机、镜头和曝光参数。
- **PDF／SVG**：单独显示页数、页面尺寸或矢量文档声明，不把查看器生成的预览尺寸当作源文件分辨率。PDF 单位是 pt，SVG 保留声明的单位。
- 缺失信息显示「未提供」，不会把未知 HDR 当作 SDR，也不会通过标称帧率推断恒定帧率。不进行视频逐帧扫描，不改变播放速度、画面缩放或源文件；参数读取不上传文件。相机信息不包含 GPS、序列号和所有者字段，但「复制全部」包含文件路径，请在对外分享前自行检查。

### 视频剪辑

- 只需填写起始时间和结束时间。
- 修改时间后可重新生成片段预览，确认无误再导出。
- 默认输出到原视频所在目录，也可以由用户另选目录；文件名自动包含起止时间，并且绝不覆盖已有文件。
- 音频使用无损编码，视频采用与源素材特征匹配的高保真编码，并校验分辨率、像素格式、色彩信息和时长。

### 逐帧截图

- 设置截图起点后，结束时间默认取起点后 5 秒，并且可以继续修改。
- 截图区间过长时会在执行前提示，避免意外生成大量图片。
- 按视频原始分辨率逐帧导出，默认保存到原视频同级目录中的独立文件夹。
- 普通素材输出无损 PNG；浮点或超高位深素材会自动使用 EXR。

### 永久旋转

- 支持将视频永久旋转 90°、180°、270° 或 360°。
- 生成新视频，不覆盖原文件。
- 默认保存到原视频同级目录，并尽量保持原有音频和其他可保留的媒体参数。
- 旋转快捷键会即时预览并自动导出：同一视频左转两次为 180°，四次恢复原方向；导出期间继续按键会排队生成最新累计角度。
- 每次都从原视频生成新文件，不把已导出的文件反复压制。取消操作会撤销尚未完成的旋转请求；切换或关闭视频会取消该视频未完成的快捷键旋转任务，已保存的文件不会删除。

为避免静默损坏画质或元数据，工具遇到当前无法安全保留的动态 HDR、异常像素格式或隔行旋转素材时会明确停止并提示，而不会悄悄降级输出。

### 视频格式转换

打开视频后，在 **视频 → 视频工具… → 格式转换** 选择输出格式和转换方式，点击开始即可。直接使用应用内置的 [FFmpeg](https://ffmpeg.org/ffmpeg.html)，不需要安装另一套软件或联网上传视频。

- 输出 **MP4、MKV、MOV**，默认 MP4。转换整段原视频，不受 A/B 循环、播放速度、画面缩放或预览旋转影响。
- 默认 **无损换封装**：不重新编码视频、音频或字幕，适合只换容器，不改善本身画质，也不保证文件显著变小。目标容器必须支持原来的编码和轨道。
- 可明确选择 **H.264 高质量** 或 **H.265 / HEVC 高质量**：使用 libx264 / libx265、CRF 18、slow 预设，保持原始尺寸与时间轴。它们是有损重编码，不等于逐像素无损，也不是 AI 超分；为质量优先使用软件编码，速度取决于素材、分辨率与机器。
- 所有模式都复制原有音轨和字幕，不偷偷压低音质、改声道或删轨。遇到不兼容编码、字幕、附件或数据轨会明确提示；可尝试 MKV。第一版不处理多个主视频轨，也不自动把 ASS 等字幕改成丢失样式的文本字幕。
- 位深、透明度、色彩或动态 HDR 无法安全保留时会拒绝转换，不自动变成 SDR。普通静态 HDR 的 HEVC 路径会校验色彩与元数据；Dolby Vision / HDR10+ 等动态 HDR 当前不支持转换。
- 默认保存在原视频同级目录，也可另选目录。自动命名为 `原名_converted_copy.mp4` 等，重名自动递增，绝不覆盖已有文件。支持进度、预计剩余时间、取消和在 Finder 中显示结果；完成轨道、尺寸、色彩、时长与章节校验后才发布文件。

方案选型比较了 [HandBrake](https://handbrake.fr/docs/en/latest/introduction/about.html) 与 [Shutter Encoder](https://github.com/paulpacifico/shutter-encoder)：前者聚焦重编码、不提供视频直通，后者本身也使用 FFmpeg 并带有 Java 界面。因此这里复用已有的固定版本 FFmpeg 核心，加上原生 Swift 界面；没有复制另一套完整 GUI，也没有新增 Java 运行环境。相关源码与许可证继续随 Release 源码包提供。

### 本地 AI 中文字幕

在原生播放器侧栏选择 **AI 字幕**，或打开 **字幕 → 生成中文字幕…**。面板分为「生成字幕」和「模型管理」，不是另开网页。

1. 先在「模型管理」阅读模型许可说明，点击「下载并准备模型」。页面逐项显示下载大小、完成量和进度，并显示实际下载速度与对应阶段的预计剩余时间。
2. 下载可以暂停；下次点「继续下载和准备」会复用已下载部分。下载完整但尚未校验的文件会进入校验，不会直接显示就绪，也不会无故重新下载全部权重。关闭面板不会取消后台任务。
3. 打开本地视频，在「生成字幕」选择原音频语言：自动识别、普通话、粤语、英语、日语或韩语，然后点击「生成字幕」。结果为简体中文字幕。
4. 默认在原视频同级目录生成新的 ASS 和 SRT 文件，绝不覆盖原视频或已有字幕。原视频仍在同一播放会话时，完成后会自动选中新生成的 ASS 字幕；已经换片或重新加载时不会误加载到其他视频。也可点击「在 Finder 中显示结果」。

固定使用质量优先的完整模型组，不提供降档或量化模型选择：

| 环节 | 固定模型 |
| --- | --- |
| 语音识别 | 官方 Qwen3-ASR 1.7B BF16 |
| 时间轴对齐 | 官方 Qwen3-ForcedAligner 0.6B BF16 |
| 翻译为中文 | Hy-MT2 30B-A3B BF16 |

锁定的三组模型文件合计约 **66 GB**，另需独立 AI 运行环境、下载校验与任务临时文件空间。长视频的分析音频及可选烧录视频还会额外占用磁盘。运行时和模型存放在 `~/Library/Application Support/io.github.SeanLi-Coder.ChengYingPlayer/SubtitleTools`，不放进源码仓库。

AI 字幕要求 **Apple Silicon、macOS 14 或更新版本，以及至少 96 GiB 统一内存**；建议使用 128 GB 统一内存机型，例如 M4 Max 128 GB。内存不足时允许预下载固定模型，但会阻止字幕生成并说明原因，不会偷偷切换低档模型。普通播放器和视频工具仍遵循下方原有系统要求。

默认不勾选「同时生成烧录字幕的新视频」：外挂字幕完全不改变原片画质和音质。勾选后会另外生成 **无损 FFV1 MKV**，复制原有音轨，文件可能非常大；遇到当前无法安全烧录的 HDR、旋转元数据等素材，会保留已经生成的外挂字幕并提示烧录问题，不会悄悄降低视频规格。

模型许可与应用源码许可是不同的：Qwen 模型采用 [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0)；Hy-MT2 使用 [Tencent Hy Community License](https://huggingface.co/tencent/Hy-MT2-30B-A3B/blob/main/LICENSE.txt)，包含用途、地区等限制，不能因为模型页面标签而将其视为 Apache 2.0。下载前请阅读并遵守相应条款。模型权重不随本仓库或源码 Release 分发。

## 本地与隐私

- 上述视频和 AI 字幕处理均在 Mac 本地运行，不会把视频、提取音频或识别结果上传到云端推理服务。
- 项目不收集视频内容，也不包含 AI 超分。只有用户主动准备字幕模型时才下载锁定的模型和独立运行环境；不依赖云端字幕账户。
- 已移除网络地址打开、在线字幕搜索和插件入口，主 App 不再附带浏览器扩展、插件安装器或网络视频下载器。这是功能精简，不是操作系统级的断网隔离。
- Release 安装包不包含个人媒体、账号、Cookie、员工邮箱或签名私钥；构建与测试使用临时合成素材。

## 系统要求

- Apple Silicon 安装包支持 M1 / M2 / M3 / M4 系列及更新机型，本地播放和视频工具需要 macOS 12 或更高版本
- 下载中心需要 macOS 13.5+，并自行安装 Google Chrome；当前不提供 Intel 或 universal 安装包
- AI 字幕为 Apple Silicon / macOS 14+ 功能，生成任务至少需要 96 GiB 统一内存；普通播放器无需这些模型
- 从源码构建需要最新公开版 Xcode 和 CPython 3.13.2

## 从源码构建

克隆本仓库后，在项目根目录执行：

```console
brew install cmake pkg-config meson ninja autoconf automake libtool
python3.13 -m venv .build/release-python
source .build/release-python/bin/activate
python -m pip install --require-hashes --only-binary=:all: -r Tools/DownloaderHelper/requirements-build.txt
bash other/build_playback_libraries.sh
./other/build_media_binaries.sh
bash other/build_image_codec.sh
Tools/VideoToolsHelper/build_helper.sh
Tools/SubtitleToolsHelper/build_helper.sh
Tools/DownloaderHelper/build_helper.sh
open iina.xcodeproj
```

完整构建使用 Apple Silicon、CPython **3.13.2** 和 Xcode；上面的 Python 必须是这个补丁版本，不能用任意 3.13。构建依赖必须装进独立、干净的 venv，不能混入 pytest 等开发包。`HELPER_PYTHON` 可指定该环境的 Python。

`build_playback_libraries.sh` 从固定源码构建 libmpv、播放 FFmpeg 和 AV1 / 字幕 / 色彩管理依赖，保留 VideoToolbox 硬解、OpenGL、CoreAudio、ICC 与 HDR 所需能力。它与视频处理使用的 FFmpeg CLI 独立；不再从其他播放器的 DMG 提取动态库。原 `download_libs.sh` 仅保留作历史开发参考，不能用于发行构建。播放依赖目前仅支持原生 arm64 构建。

播放库包含明确记录的 ICC 内存所有权修复与配置同步补丁，避免加载屏幕色彩配置时崩溃或配置未生效。`bash Tools/ICCProfileTests/run.sh` 使用真实 OpenGL / LCMS 检查借用内存、重复切换和 sRGB / Display P3 渲染像素；补丁、原始源码及修改前后校验值随对应 Release 源码包提供。

媒体处理工具、WebP 编码器和三个 helper 也由固定输入构建。下载模块复用 Playwright 内置 Node 执行 yt-dlp 的 JavaScript 求解，不再额外打包 Deno；不改变原有下载质量、登录、代理和重试策略。AI 字幕在用户主动准备模型时建立独立运行环境。

完整 App 通过验证后，用 `bash other/package_dmg.sh /绝对路径/ChengYing.app /已有输出目录/ChengYingPlayer-v<版本>-Apple-Silicon.dmg` 打包。脚本不会修改输入 App，不覆盖已有输出，并验证签名、arm64、内部动态依赖、只读挂载和拷贝完整性。正式 Developer ID 签名与公证需要自己的 Apple 开发者凭据；不得使用上游身份或在仓库中提交私钥。

每个安装版 Release 的源码归档包含同一提交的项目、Swift 包、播放栈、媒体工具、helper 对应依赖源码与播放构建记录。具体版本、校验值与许可证见 [`other/third_party_sources.sh`](other/third_party_sources.sh)、[`other/playback_sources.sh`](other/playback_sources.sh)、[`Tools/DownloaderHelper/runtime-sources.json`](Tools/DownloaderHelper/runtime-sources.json)、[`NOTICE.md`](NOTICE.md) 和 [`Legal/THIRD_PARTY_NOTICES.md`](Legal/THIRD_PARTY_NOTICES.md)。依赖或选项变化时，必须同步更新源码、通知、校验和回归测试。

## 参与开发

播放稳定性专项检查：`bash Tools/ThumbnailLifecycleTests/run.sh` 验证真实请求生命周期；`bash Tools/ThumbnailCacheTests/run.sh` 验证损坏缓存与清理；`bash Tools/RenderLifecycleTests/run.sh` 验证 CGL 引用与退出锁顺序。准备好播放动态库和媒体工具后，`bash Tools/ThumbnailDecoderTests/run.sh` 验证实际 FFmpeg 缩略图解码，执行 `PLAYBACK_SOAK_SECONDS=600 bash Tools/PlaybackSoakTests/run.sh` 可做 10 分钟真实 4K 硬件解码与 OpenGL 渲染检查；明确设置 `PLAYBACK_SOAK_MODE=software` 才使用软件解码，测试结果会分别标示，不把软件回退当作硬件验证成功。详细范围见各测试目录的 README。

图片专项检查：`bash Tools/ImageViewerTests/run.sh`、`bash Tools/ImageViewerUITests/run.sh`、`bash Tools/ImageRoutingTests/run.sh`、`bash Tools/ImageSlideshowTests/run.sh`、`bash Tools/ImageSlideshowUITests/run.sh`。幻灯片覆盖实际 AppKit 控件、Finder 多色标签、排序、慢图 / 坏图 / 动图、动态间隔、最小化恢复与转换隔离，并使用临时偏好域。先运行 `bash other/build_image_codec.sh` 再运行 `bash Tools/ImageCodecHelper/run.sh`，可测试真实 WebP 像素、动画时序、透明度、ICC、安全限制与取消。测试只生成临时素材，不读取个人相册。完整 App 由 CI 构建、签名验证及 DMG 打包检查。

欢迎提交中文界面、播放兼容性、剪辑准确性、逐帧导出、旋转处理、可访问性和稳定性方面的改进。提交前请确认：

- 没有提交本地视频、账号配置、证书、签名密钥或其他私人文件。
- 新增依赖的许可证与 GPLv3 兼容，并保留必要的版权和许可证声明。
- 行为变更附带相应测试，媒体处理功能覆盖取消、失败、磁盘空间不足和输出文件重名等情况。

在 Mac 上执行 `./Tools/VideoToolsTests/run.sh` 可运行原生播放与打点回归检查；只需 Xcode Command Line Tools。检查直接编译真实的工具界面和播放器桥接代码，使用模拟播放器验证按钮、区间预览、打点精度、刷新定时器与中文布局，并覆盖固定快捷键解析、循环边界策略和累计旋转队列。完整 App 构建、真实 mpv 循环边界冒烟检查和媒体处理测试由 GitHub Actions 继续验证。

画面缩放与平移专项检查：`bash Tools/VideoViewportTests/run.sh` 使用真实 AppKit 窗口、键盘事件和生产桥接代码检查快捷键、范围限制、复位、焦点保护及播放状态不变；准备好播放动态库和媒体工具后，`bash Tools/VideoViewportTests/Live/run.sh` 对合成 4K 视频进行真实 mpv / OpenGL 像素检查，验证缩放比例、四向平移和窗口尺寸不变。默认要求硬件解码，CI 明确设置 `VIDEO_VIEWPORT_LIVE_MODE=software` 使用软件解码，两种结果分别标示。

`./Tools/SimplificationTests/run.sh` 验证原生命令可用性与精简后的菜单、设置资源，防止已移除功能通过旧入口重新出现。
`bash Tools/PreferenceSearchTests/run.sh` 使用真实 AppKit 设置搜索实现，验证隐藏项目不会被搜出、可用的折叠项目仍可搜索并自动展开。
`bash Tools/VisualStyleTests/run.sh` 与 `bash Tools/WelcomeDesignTests/run.sh` 检查原生样式、按钮行为和欢迎页；设置 `CHENGYING_CAPTURE_DIR` 后运行欢迎页或视频工具测试，可输出真实 AppKit 界面截图用于布局检查。

`bash Tools/PlaylistMetadataTests/run.sh`、`bash Tools/PlaylistPlaybackTests/run.sh` 与 `bash Tools/PlaylistPresentationTests/run.sh` 验证 Finder 多色标签、目录筛选、四种稳定排序、保留播放会话的队列移位，以及深浅主题与最窄侧栏布局。测试只对新建临时文件写入测试标签，不更改用户视频。

继承的播放器代码另有专项回归：`bash Tools/PlaybackTimeTests/run.sh` 检查时间进位、非法输入和异常时长；`bash Tools/HistorySearchTests/run.sh` 检查历史刷新后保留搜索条件；`bash Tools/PlaybackLifecycleTests/run.sh` 复现快速切文件后停止/退出的后台任务竞争，并用 Address Sanitizer 检查滤镜节点访问；`bash Tools/WindowLifecycleTests/run.sh` 通过真实 AppKit 滚动事件验证触控板取消、惯性灵敏度和窗口缩放收尾。播放列表测试还覆盖右键菜单打开后列表变化，避免误操作另一个文件；文件回收在测试中被替换为记录器，不会删除用户文件。

`bash Tools/AutoFileMatchingTests/run.sh` 运行完整的同目录字幕自动匹配流程，验证第 1 集不会因为名称包含关系而抢走第 10 集的字幕，同时保留语言后缀、发行前缀与原有剧集匹配规则。

AI 字幕的原生界面与离线 helper 回归测试：

```console
bash Tools/SubtitleToolsTests/run.sh
python3 -m unittest discover -s Tools/SubtitleToolsHelper/tests
```

原生检查编译真实 AppKit 界面、共享任务服务及 IPC 客户端，覆盖中英文 340 点侧栏、下载/校验/暂停状态、任务互斥、输出路径验证和字幕自动加载的媒体会话隔离。离线 helper 检查不下载大模型；模拟测试通过不等于已经在目标 Mac 上完成全模型性能或翻译质量验收。模型与运行环境版本、文件大小、SHA-256 锁定记录见 [`Tools/SubtitleToolsHelper/assets.json`](Tools/SubtitleToolsHelper/assets.json)。

下载中心的离线回归检查（使用固定依赖环境，不读取真实 Cookie、不下载网站内容）：

```console
python3 -m pip install --require-hashes --only-binary=:all: -r Tools/DownloaderHelper/requirements-dev.txt
python3 Tools/DownloaderHelper/verify_vendor.py
python3 Tools/DownloaderHelper/run_upstream_tests.py
python3 -m pytest -q Tools/DownloaderHelper/tests
bash Tools/DownloadCenterTests/run.sh
```

原下载器测试会在临时副本运行，避免在应用源码或原项目目录创建任务数据。打包时还会实际启动冻结后的 Playwright 驱动、Node 和下载服务，核对真实 JavaScript 求解、动态端口认证、任务目录隔离、重复进程锁、重启与父进程退出清理。

## 开源许可与版权

下载中心保留原迹下载器的 MIT 许可和版权，并保留其固定依赖的许可证与来源清单；不会移除上游声明来隐藏来源。

本项目是 [IINA v1.4.4](https://github.com/iina/iina/releases/tag/v1.4.4) 的修改版本，修改工作自 2026-09-16 起进行。项目整体继续依照 [GNU General Public License v3.0](LICENSE) 发布。

IINA 原始部分版权归 Collider LI 及 IINA contributors 所有；澄影播放器新增和修改部分的版权归各自贡献者所有。项目使用独立名称与标识，不代表 IINA 项目或其维护者对本项目提供认可、担保或支持。

完整的来源、修改声明和第三方组件归属见 [NOTICE.md](NOTICE.md) 与 [`iina/Credits.rtf`](iina/Credits.rtf)。未来如果分发二进制，必须先确保可同时提供与该二进制完全对应、可用于重新构建的源码和构建脚本。当前 CI 会阻止应用二进制成为 Actions artifact 或 GitHub Release 资产。
