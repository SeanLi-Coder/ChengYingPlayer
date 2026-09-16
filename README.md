# 澄影播放器（ChengYingPlayer）

<p align="center">
  <img src="Brand/ChengYingIconMaster.png" width="180" alt="ChengYingPlayer icon">
</p>

一款面向 macOS 的中文媒体播放器，兼顾日常播放、轻量视频处理、本地 AI 中文字幕与原画质素材下载。视频、音频和字幕处理在本机完成，不包含 AI 超分或云端转码。

原生界面采用石墨色与冰蓝点缀，提供深浅两套外观：欢迎页集中呈现打开文件、继续上次与最近播放；工具面板按操作分组，并将主要导出按钮固定在底部；AI 字幕的生成、模型和任务状态以独立卡片呈现。播放器时间轴与侧栏采用统一的强调色，保留原有快捷键和无障碍操作，不添加影响观影的装饰动画。

界面保留本地播放、视频处理和独立下载中心需要的入口：不提供网络地址直接播放、在线字幕搜索、插件、浏览器扩展和开发调试菜单。字幕加载、播放列表、章节、画中画、播放历史和快捷键设置仍然保留；旧版本保存的插件工具栏按钮会自动隐藏，旧的在线字幕自动搜索和高级 mpv 配置不再执行。

### 精简的功能范围

- 不再提供音乐迷你模式或自动切换音乐窗口；音频文件仍可在主窗口正常播放。旧音乐模式快捷键与工具栏按钮不会重新启用该模式。
- 移除通用音视频滤镜编辑器、保存的滤镜预设与去台标入口；保留播放时的画面裁剪、翻转、去隔行与基本画面调整。
- 移除不可恢复的“永久删除源文件”快捷键命令，保留“移到废纸篓”和“在 Finder 中显示”。视频处理始终另存新文件。
- 设置中移除无实际作用的自动更新选项、“恢复隐藏提示”，以及 ReplayGain、手动解码线程、强制独显、实验音频驱动、音乐无缝播放、SPDIF 直通等高级项目；使用安全的自动/中立配置。旧偏好数据不会被删除，但不再影响这些已移除功能。
- 保留硬件解码、HDR、ICC 色彩管理、音频输出设备、字幕/音画同步、播放速度与 A/B 循环；设置搜索仅显示仍然可用的项目。

## 当前发布方式

当前 GitHub Releases **仅发布源码，不提供 App、DMG 或 ZIP 安装包**。CI 会在临时环境中构建并测试应用，但不会上传或发布该应用二进制。

这是因为当前本地/CI 构建使用的预编译播放动态库还没有完整闭合到可用、精确匹配的对应源码与构建记录。在播放栈全部由固定版本源码重建并完成合规验证之前，项目不会对外分发应用二进制。

Release 中的 `ChengYingPlayer-<tag>-Release-Source.tar.gz` 是便于审核和本地构建的源码归档，不是可直接运行的安装包，也不是对任何未分发播放二进制的源码要约。

## 核心功能

除完整的本地音视频播放、字幕、播放列表、章节、画中画与播放历史外，澄影播放器提供三项视频处理工具、独立的 AI 中文字幕面板与下载中心，无需离开播放器：

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
- 默认保存到 `~/Downloads/ChengYing`，仍按作者和原来的命名规则整理；可用原生「选择文件夹」更改，再点击「保存设置」。下载完成的视频可直接点「播放」，图片和视频都可在 Finder 中显示。
- 文件列表的展开、收起状态会在定时刷新和实时任务更新后保留，避免准备播放时列表突然折叠。
- 关闭下载中心窗口后，后台任务继续运行；退出播放器会停止任务，已下载文件保留。下次打开后，可按原界面的提示继续或重试，不会自动无提示启动旧任务。
- Chrome Cookie 默认开启，保留账号绑定和显式匿名模式，不会因账号读取失败静默改成匿名请求。首次读取 Chrome 登录态可能触发 macOS 钥匙串授权；只应下载自己有权访问和保存的内容。

下载中心当前固定为 **Apple Silicon、macOS 13.5 或更新系统**。Python、Playwright 驱动、yt-dlp、Deno 和媒体工具由构建流程打包，不要求最终用户安装开发环境；**Google Chrome 仍需用户安装并登录**，播放器内的网页不是 Chrome 登录环境。该模块不会提高其他本地播放功能的最低系统要求。站点的限流、登录、地区、内容权限和临时接口变更仍可能阻止下载；这里不是绕过网站限制的服务，也不新增直播或 DRM 内容支持。

任务和设置独立保存在 `~/Library/Application Support/io.github.SeanLi-Coder.ChengYingPlayer/DownloadCenter`。不会自动读取、迁移或修改原 `rednote_downloader` 项目的任务目录；不会把 Cookie、浏览器用户数据、下载文件或个人配置打包进应用源码。内置服务仅监听随机本机端口，页面、API、静态资源和实时事件流均需要每次启动的新会话凭据，拒绝外部网页跨来源访问。

完整源码、来源哈希及迁移补丁说明见 [`Tools/DownloaderHelper/UPSTREAM.md`](Tools/DownloaderHelper/UPSTREAM.md)。原有回归测试与新增的会话隔离、原生桥接、冻结打包和退出测试在 CI 中运行；离线测试通过不等于所有网站、账号和网络环境都已实时实测成功。

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

按 B 前必须先设 A，且 B 必须晚于 A；0 秒可以作为 A。循环与工具侧栏是否打开无关，暂停时设置 B 会保持暂停，按空格即可继续循环播放。关闭当前文件会清除循环。若异常素材经过多次精确定位仍无法回到区间，播放器会暂停并提示，避免继续越界播放。

左右 Command 会分别识别，右 Command 不触发永久旋转。长按旋转或打点键不会重复导出或反复改写边界；松开后再次按下才累计。上述固定键优先于旧的自定义键位配置。

其他默认快捷键也保留：空格播放/暂停，左右方向键前后跳转 5 秒，Option + 左右方向键逐帧定位，Command + `[` / `]` 减半/加倍播放速度，Command + `\` 恢复正常速度。循环单文件改为 Option + Command + L，在 Finder 中显示文件改为 Option + Command + R。其他键位可以在设置中自定义。

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
- 当前本仓库不发布可安装二进制；如需使用，请审查并自行从源码构建。

## 系统要求

- Apple Silicon 源码构建目标需要 macOS 12 或更高版本
- Intel Mac 源码构建的最低部署目标为 macOS 10.15
- AI 字幕为 Apple Silicon / macOS 14+ 功能，生成任务至少需要 96 GiB 统一内存；普通播放器无需这些模型
- 从源码构建需要最新公开版 Xcode 和 CPython 3.13.2

## 从源码构建

克隆本仓库后，在项目根目录执行：

```console
./other/download_libs.sh
brew install cmake pkg-config
python3 -m pip install --require-hashes --only-binary=:all: -r Tools/DownloaderHelper/requirements-build.txt
./other/build_media_binaries.sh
Tools/VideoToolsHelper/build_helper.sh
Tools/SubtitleToolsHelper/build_helper.sh
Tools/DownloaderHelper/build_helper.sh
open iina.xcodeproj
```

`download_libs.sh` 默认下载 universal 动态库，也可以只下载指定架构：

```console
./other/download_libs.sh --arch arm64
./other/download_libs.sh --arch x86_64
```

以上完整构建使用 Apple Silicon、CPython **3.13.2** 和 Xcode；`HELPER_PYTHON` 可指定安装固定依赖的 Python。媒体工具构建脚本会下载并校验固定版本的 FFmpeg、x264、x265，以及 libass 和其字幕渲染依赖源码，再由源码生成 App 内置的 `ffmpeg`、`ffprobe`。脚本默认将 Apple Silicon 的最低系统版本固定为 macOS 12.0、Intel 固定为 macOS 10.15；可以通过 `MACOSX_DEPLOYMENT_TARGET` 显式提高目标版本，但不能低于对应架构的默认值，构建结束后还会检查实际 Mach-O 最低版本。helper 使用固定版本的 CPython 与 PyInstaller 构建；下载中心另外校验完整依赖锁并打包自己的 Node/Deno，单独要求 macOS 13.5。AI 字幕另在用户主动准备模型时建立校验锁定的独立运行环境，因此最终用户无需安装 Homebrew、系统 Python 或 FFmpeg。Intel 的本地媒体工具还需要 `brew install nasm`，但不支持 AI 字幕推理或当前固定的下载中心运行环境。随后在 Xcode 中选择应用 target 并构建。用于公开分发的构建还需要配置自己的 Developer ID、签名、notarization 和更新渠道；不得继续使用上游项目的签名身份或更新地址。

每个带标签的源码 Release 都附带由同一提交生成的 `Release-Source.tar.gz`、SHA-256 校验文件和独立的第三方源码清单。归档包含项目源码、构建脚本以及经过 SHA-256 校验的 FFmpeg、x264、x265、CPython、PyInstaller 和 helper 构建依赖源码包。它用于该源码版本的重建与审核，不宣称为未发布播放二进制的完整对应源码。具体版本、校验值与许可证见 [`other/third_party_sources.sh`](other/third_party_sources.sh)、[`NOTICE.md`](NOTICE.md) 和 [`Legal/THIRD_PARTY_NOTICES.md`](Legal/THIRD_PARTY_NOTICES.md)。

如果需要自行构建 mpv 和 FFmpeg，请参考 [`other/`](other/) 中的构建与依赖处理脚本。动态库、编译选项和许可证必须与实际发布版本保持一致。

## 参与开发

欢迎提交中文界面、播放兼容性、剪辑准确性、逐帧导出、旋转处理、可访问性和稳定性方面的改进。提交前请确认：

- 没有提交本地视频、账号配置、证书、签名密钥或其他私人文件。
- 新增依赖的许可证与 GPLv3 兼容，并保留必要的版权和许可证声明。
- 行为变更附带相应测试，媒体处理功能覆盖取消、失败、磁盘空间不足和输出文件重名等情况。

在 Mac 上执行 `./Tools/VideoToolsTests/run.sh` 可运行原生播放与打点回归检查；只需 Xcode Command Line Tools。检查直接编译真实的工具界面和播放器桥接代码，使用模拟播放器验证按钮、区间预览、打点精度、刷新定时器与中文布局，并覆盖固定快捷键解析、循环边界策略和累计旋转队列。完整 App 构建、真实 mpv 循环边界冒烟检查和媒体处理测试由 GitHub Actions 继续验证。

`./Tools/SimplificationTests/run.sh` 验证原生命令可用性与精简后的菜单、设置资源，防止已移除功能通过旧入口重新出现。
`bash Tools/PreferenceSearchTests/run.sh` 使用真实 AppKit 设置搜索实现，验证隐藏项目不会被搜出、可用的折叠项目仍可搜索并自动展开。
`bash Tools/VisualStyleTests/run.sh` 与 `bash Tools/WelcomeDesignTests/run.sh` 检查原生样式、按钮行为和欢迎页；设置 `CHENGYING_CAPTURE_DIR` 后运行欢迎页或视频工具测试，可输出真实 AppKit 界面截图用于布局检查。

`bash Tools/PlaylistMetadataTests/run.sh`、`bash Tools/PlaylistPlaybackTests/run.sh` 与 `bash Tools/PlaylistPresentationTests/run.sh` 验证 Finder 多色标签、目录筛选、四种稳定排序、保留播放会话的队列移位，以及深浅主题与最窄侧栏布局。测试只对新建临时文件写入测试标签，不更改用户视频。

继承的播放器代码另有专项回归：`bash Tools/PlaybackTimeTests/run.sh` 检查时间进位、非法输入和异常时长；`bash Tools/HistorySearchTests/run.sh` 检查历史刷新后保留搜索条件；`bash Tools/PlaybackLifecycleTests/run.sh` 复现快速切文件后停止/退出的后台任务竞争，并用 Address Sanitizer 检查滤镜节点访问；`bash Tools/WindowLifecycleTests/run.sh` 通过真实 AppKit 滚动事件验证触控板取消、惯性灵敏度和窗口缩放收尾。播放列表测试还覆盖右键菜单打开后列表变化，避免误操作另一个文件；文件回收在测试中被替换为记录器，不会删除用户文件。

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

原下载器测试会在临时副本运行，避免在应用源码或原项目目录创建任务数据。打包时还会实际启动冻结后的 Playwright 驱动、Deno 和下载服务，核对动态端口认证、任务目录隔离、重复进程锁、重启与父进程退出清理。

## 开源许可与版权

下载中心保留原迹下载器的 MIT 许可和版权，并保留其固定依赖的许可证与来源清单；不会移除上游声明来隐藏来源。

本项目是 [IINA v1.4.4](https://github.com/iina/iina/releases/tag/v1.4.4) 的修改版本，修改工作自 2026-09-16 起进行。项目整体继续依照 [GNU General Public License v3.0](LICENSE) 发布。

IINA 原始部分版权归 Collider LI 及 IINA contributors 所有；澄影播放器新增和修改部分的版权归各自贡献者所有。项目使用独立名称与标识，不代表 IINA 项目或其维护者对本项目提供认可、担保或支持。

完整的来源、修改声明和第三方组件归属见 [NOTICE.md](NOTICE.md) 与 [`iina/Credits.rtf`](iina/Credits.rtf)。未来如果分发二进制，必须先确保可同时提供与该二进制完全对应、可用于重新构建的源码和构建脚本。当前 CI 会阻止应用二进制成为 Actions artifact 或 GitHub Release 资产。
