# M4 Max / Qwen 联合开发交接

这份文档供同一 GitHub 项目的不同机器和编程助手共用。入口是根目录
[`AGENTS.md`](../AGENTS.md)；另有 [`QWEN.md`](../QWEN.md) 和兼容的 `CLAUDE.md` 简短入口。
如果客户端不会自动读取，请在任务开头明确要求它阅读 `AGENTS.md` 与本交接文档。

**当前协作者：**用户于 2026-09-25 将 M4 Max 上的编程助手从 GLM 改为 Qwen。
后续交接面向 Qwen；已有 GLM 提交、日志和文件名保留历史归属，不批量改名，也不要求继续使用 GLM。
此变更只涉及联合开发助手，不更换播放器内的字幕或总结模型，也不自动指定谁负责下一次发布。

仓库：[SeanLi-Coder/ChengYingPlayer](https://github.com/SeanLi-Coder/ChengYingPlayer)。
这是澄影视界播放器，不是独立的 Local Video Cutter 项目。
文档中的历史观察截至 **2026-09-25**；开始前以当前源码、用户新要求和实际测试为准。

## 1. 开始前先做这些

1. 阅读根目录 `AGENTS.md`，涉及下载中心时再完整阅读
   [`Tools/DownloaderHelper/UPSTREAM.md`](../Tools/DownloaderHelper/UPSTREAM.md)。
2. 查看 `git status --short`、`git branch --show-current`、`git log -1 --oneline`。
   先确认现有改动的归属，不覆盖、不重置其他助手或用户的工作。
3. 工作树干净时同步远端，再从最新 `main` 建立独立功能分支，例如
   `codex/kuaishou-m4`。已有改动时先处理交接，不强行切换或拉取。
4. 一次只处理用户当前委托的范围。本文的待验证问题不是自动执行全部功能的授权。
   并行工作尽量按文件或模块划分，不同时修改同一个文件。
5. 提交使用 English commit message 和 GitHub 提供的隐私 `noreply` 邮箱，
   不使用或公开员工邮箱。中文用于用户说明，代码、注释、标识符和日志用 English。

推荐协作方式：M4 Max 上完成真实站点验证并提交分支或 PR，另一台机器审查差异、
补充可重复回归，之后沿项目现有流程整合。不要 force-push 共用分支；发生冲突先核对双方意图。
提交代码、CI 通过、发布草稿、正式上线是不同状态，分别说明。

## 2. 当前快手任务的边界

- 用户希望在播放器下载中心输入单视频、分享链接或作者主页，下载其有权保存的作品，
  主页尽可能完整，使用网站当前会话可提供并能验证的最高画质，保留进度、取消、重试和代理。
- **用户已取消独立快手测试包方案。** 本机独立 v1/v2 包和未发布的 v2.0.1 修补代码
  已移出工作区；`Tools/KuaishouDownloadKit` 不属于正式仓库依赖。不要要求用户继续运行旧 ZIP，
  不要重新创建旁路工具代替修复播放器，除非用户另行要求。
- 正式播放器快手实现与测试仍在，不能把名字含 `test_kuaishou` 的回归测试也删掉。
- 先前开发机访问目标站点受网络过滤／TLS 问题影响，没有验证该作者真实全量下载成功。
  用户浏览器能看见作品，也不证明程序使用同一登录态、同一网络路线或已遍历全部作品。
- 截至交接，最近一次有完整发布证据的播放器版本是 v0.2.34；这不是永久的最新版本声明。
  新机器应重新核实实际安装版本、源码提交和当前发布状态。

## 3. 正式代码入口

| 范围 | 仓库路径 |
| --- | --- |
| 快手网页发现、作者归属、分页与浏览器请求 | `Tools/DownloaderHelper/vendor/rednote/app/kuaishou.py` |
| 平台类型、链接识别 | 同目录 `models.py`、`platforms.py` |
| 媒体下载、任务队列、取消重试 | 同目录 `downloader.py`、`task_manager.py` |
| HTTP API、状态脱敏、下载界面 | 同目录 `main.py`、`static/app.js`、`static/index.html` |
| 原生宿主与代理 | `Tools/DownloaderHelper/helper.py`、`proxy_config.py`、`proxy_transport.py` |
| 播放器下载窗口与桥接 | `iina/DownloadCenter/` |
| 快手专项回归 | `Tools/DownloaderHelper/tests/test_kuaishou.py`、`test_kuaishou_frontend.py` |
| 来源清单与校验 | `Tools/DownloaderHelper/upstream-manifest.json`、`verify_vendor.py`、`UPSTREAM.md` |
| 构建、完整验证、正式发布 | `.github/workflows/ci.yml`、`README.md` 的开发构建章节 |

保留小红书、抖音、B站、YouTube 的已有行为，不为快手重写一个缩水版下载中心。
原生 WKWebView 是本地下载界面，不能当作 Chrome 的登录和网页解析环境。

## 4. 已踩过的坑与待验证事项

### 请求转发：分清 JavaScript 与 Python

已取消的独立 JavaScript 包曾在 `route.fetch({postData: null})` 中把无正文 GET
变成带 JSON `null` 正文的请求。严格校验请求的服务器会拒绝 CSS、JS，出现裸 HTML 页面。
本地真实 Chrome 和本地 HTTP fixture 曾复现这一点；它不是用户必须重装 Chrome 的证据。

正式播放器使用 **Python Playwright**，`None` 与 JavaScript `null` 的序列化不同。
不能据此声称正式播放器也存在相同 GET 故障，或把废弃包的修补写成已发布。

正式 `fulfill_checked_route` 值得优先增加真实回归的源码风险（尚非本轮现场修复结果）：

- POST 经 301/302/303 改为 GET 后，把正文设为 `None` 是否会让 `route.fetch` 重新继承原请求正文。
- 过滤后的空 headers 是否被 Playwright 的默认逻辑替换为原始请求头。
- HEAD 遇到 303 是否保持 HEAD；转换 GET 后是否移除正文相关请求头；307/308 是否保留原字节。
- CSS/JS 请求失败、HTTP 错误、错误 MIME 或脚本异常是否能给出脱敏、可操作的诊断，
  而不是只显示“没有发现作品”。可选资源失败也不能直接等同于整个下载失败。

请检查当前锁定版本的 Playwright 实现，用真实 Chrome + 本地 fixture 记录方法、正文和头，
同时断言 CSS 实际生效、JS 实际执行。仅 mock `route.fetch` 参数不够。
可研究同 BrowserContext 的 URL-only `context.request.fetch`，但必须验证 Cookie／Set-Cookie、
已配置代理、重定向和响应释放等语义，不能机械替换。

### 主页完整性与画质

- 正式源码在交接时仍有 300 秒、500 页、10,000 条保护上限；不要把废弃独立包中曾经放开的
  上限当作正式功能已实现。大主页若触及上限，应报告不完整，不能假报全部完成。
- 如果当前任务需要改进长主页支持，要同时设计取消、限流、停滞提示、去重和恢复，
  不只是删掉数值保护。页面不动、滚到底、重复页或旧检查点都不能单独证明本次已到末页。
- 核对作品 ID、作者归属、连续分页及网站明确结束证据；不能混入推荐视频或其他作者作品。
- “最高画质”是当前网站返回且能核实的档位，不保证作者原始文件。无尺寸默认流不能冒充最高档，
  更不能拿封面替代视频；跨编码码率不可直接等同于视觉质量。
- 保留原有 FFprobe、文件长度、媒体类型及身份校验；不静默降档、不擅自转码。
  恢复任务不能拼接不同版本内容，不能覆盖已有用户文件。

### 网络、登录与隐私

- 先区分系统网络过滤、TLS 证书失败、账号登录、验证码、限流和页面结构变化。
  不用关闭证书验证、修改系统代理／DNS 或陌生公共代理来让测试变绿。
- 保留逐跳可信 HTTPS 目标检查、跨站认证信息保护和超时／取消；
  `route.continue_()` 不等于每一次自动重定向都会再次经过路由检查。
- 沿用现有 HTTP、HTTPS、SOCKS5 代理链路；HTTP 代理也可以连接 HTTPS 网站。
  代理失败不能静默直连；不要只测试首页而遗漏浏览器 API、媒体传输和重试。
- 遵循 App 的显式登录、Chrome Cookie 和匿名选项，不擅自切换账号或导入其他浏览器资料。
  验证码由用户在正常界面完成；不绕过私密内容权限、DRM 或站点访问限制。
- 不提交或分享 Cookie、token、代理密码、浏览器资料、HAR、原始网页、签名媒体链接、
  个人媒体、真实用户报告或员工邮箱。需要测试样本时使用合成、公开可再分发且脱敏的 fixture。
  发布截图前检查账号、文件路径和其他私人内容。

## 5. M4 Max 测试方式

从仓库根目录运行。开发测试环境与发行构建环境分开，不能把 pytest 等开发依赖打入 App。
先检查 Python、Node.js、FFmpeg／FFprobe 和 Google Chrome 是否可用；正式完整构建还需要
完整 Xcode、原生 arm64 及仓库要求的 **CPython 3.13.2**。依赖锁以仓库文件为准，不随意升级。

首次创建独立测试环境时使用一个未占用的路径，以下 `.build/m4-tests` 是示例：

```bash
python3.13 -m venv .build/m4-tests
source .build/m4-tests/bin/activate
python -m pip install --require-hashes --only-binary=:all: -r Tools/DownloaderHelper/requirements-dev.txt
```

已有环境就先核实并复用，不覆盖未知环境；不要安装到系统 Python。
旧 `.build/glm-tests` 如仍可用也可以复用，不必因更换编程助手而重建或重命名。
`.build/` 是忽略目录，不提交环境或下载数据。Google Chrome 是此集成的运行依赖，
不要以安装另一个 Chromium 后端来掩盖 Chrome 特有行为。

最小快手验证：

```bash
python Tools/DownloaderHelper/verify_vendor.py
python -m pytest -q -rs Tools/DownloaderHelper/tests/test_kuaishou.py Tools/DownloaderHelper/tests/test_kuaishou_frontend.py
```

下载中心合并前的扩展验证：

```bash
python -m ruff check Tools/DownloaderHelper --exclude vendor
python -m pytest -q -rs Tools/DownloaderHelper/tests
python Tools/DownloaderHelper/run_upstream_tests.py
node Tools/DownloaderProxyUITests/main.mjs
bash Tools/DownloadCenterTests/run.sh
```

缺少 Node、FFmpeg 或 Chrome 会导致部分测试跳过。报告通过、失败、跳过数量及跳过原因；
“测试命令退出 0”不等于真实浏览器测试已执行。上游测试用现有隔离 runner，
不直接对用户真实下载目录导入／启动 `app.main`；本地服务、素材和浏览器状态使用临时目录。
完整 CI 和发行检查不能由这组最小命令替代。

真实站点验收独立于离线回归。在用户允许的账号、网络和目标链接下，至少分别记录：

1. 单视频与分享链接：正确作品／作者、最高返回档位、真实文件参数与播放结果。
2. 作者主页：去重作品数、实际分页、是否有明确结束证据；未知总数不编百分比或 ETA。
3. 取消再继续、重启恢复、单项失败、已完成文件重试和保存位置，确认不损坏旧文件。
4. 用户实际使用的代理／直连和登录模式；验证未授权跨站请求被拒绝。

不把匿名失败等同于登录失败，不把浏览器可见等同于下载成功，也不为测试自动抓取
账号下的其他内容。对完整大主页测试先核对目标、磁盘空间及用户希望的范围。

## 6. 修改 vendor 文件时必须同步来源清单

先阅读 `UPSTREAM.md` 和 `verify_vendor.py`，再检查实际变更清单。

- `app/kuaishou.py` 是本项目新增文件：更新 `integration_files` 对应条目的 `sha256`。
- 对已有上游文件的批准补丁，只更新 `files` 对应条目的 `vendored_sha256`，
  保留 `upstream_sha256`、原始版本、提交和许可证，不伪造上游来源。
- 需要新增补丁路径或集成文件时，明确说明理由，同步 manifest 中的清单／说明与校验器
  允许集合，并增加回归；不能删除校验、扩大忽略目录或批量改写全部哈希来绕过失败。
- 哈希可用 `shasum -a 256 <changed-file>` 核对。只接受已审阅的实际源码变化，
  修改后重新运行 `verify_vendor.py` 及相关测试。
- 保留播放器及各组件的 LICENSE、NOTICE、来源和必要归属信息，品牌名称变化不改变许可证义务。

## 7. 交回给另一台机器的内容

提交／PR 描述中给出以下结构；公开内容必须脱敏：

```text
Base commit:
Branch / commit / PR:
Scope and changed files:
Tests: exact commands, passed / failed / skipped counts
Live verification: environment, login/proxy mode, observed result
Limitations / blockers:
Remaining work:
Release status: not released / draft / publicly verified
```

长任务可在 `docs/handoffs/` 新建按日期命名的简短 Markdown，使用同一结构，
不用聊天原文或带账号信息的日志替代交接。当前机器不知道的结果直接标为未验证。
没有新动作就说明没有新动作，不把历史修复写成正在开发，不估造时间或进度。

## 8. 合并与发布不能跳过的约定

用户要求播放器功能修复验证后继续完成发布；完整要求见根目录 `AGENTS.md`。
多机器协作时指定一方负责版本、标签和发布，另一方提交功能分支，避免同时发版。

- 不改 Bundle ID、稳定更新源和 Ed25519 身份，不重置用户关闭自动更新的选择。
- 正式版本与 build number 递增；运行所涉功能、自动更新、签名安装和完整 CI 检查。
- 六个基础发行附件及清单声明的全部增量包／校验和齐全并验证后才发布；增量须真实应用并确认
  与完整包的新 App 逐文件一致，始终保留完整包回退。之后匿名核实 latest、实际客户端 feed、
  完整 DMG 与全部增量包的大小及哈希。
- 不覆盖已发布附件、不移动旧标签，不跳过失败门禁。没有签名权限时报告阻碍，
  不复制另一台机器的私钥或读取无关秘密。
- 更新不能打断播放、处理或下载，不能删除模型、媒体、设置、任务历史。
- `main` push／PR 会触发现有 CI；当前只有版本标签才触发正式发布任务。
  普通 push 或 CI 绿灯不代表播放器已发布。纯文档交接不增加播放器版本或创建发布标签。

## 9. 最新 Codex review 交接

截图默认 JPG 见
[`2026-09-26 JPG 截图交接`](handoffs/2026-09-26-jpg-screenshots.md)。
`v0.2.41` / build `52` 已于北京时间 2026-09-26 07:19:37 正式发布，标签提交 `9fd3e9e5`。
普通和逐帧截图默认高质量 JPG，保留原尺寸与明确保存的格式偏好，并可选无损 PNG/EXR；
图片格式转换默认值不变。主线 CI `36198191054` 与标签 CI `36198196356` 全部通过，
八资产及匿名更新交付已验证。从 v0.2.40 的补丁为 1289790 字节（约 1.29 MB）。
这是当前最新发布记录；下面保留上一轮增量更新与代码审查证据。

增量更新与升级配置保留见
[`2026-09-26 增量更新交接`](handoffs/2026-09-26-incremental-updates.md)。
`v0.2.40` / build `51` 已于北京时间 2026-09-26 06:17:33 正式发布，标签提交 `49534044`。
主线 CI `36192458001` 和标签 CI `36192556109` 通过，八资产和公开自动更新交付已验证。
从 v0.2.39 的补丁为 997706 字节（约 1 MB），完整包为 167994145 字节（约 168 MB）；
公开补丁实际还原与公开新版逐文件一致，详见交接。保留完整包回退，不保证跳过版本也走增量。
这条保留首个增量更新版本的发布证据；下面 v0.2.39 记录保留上一轮审查证据。

**Qwen 接手时先读本轮最新记录：**
[`2026-09-26 Qwen 提交复核与发布交接`](handoffs/2026-09-26-qwen-review.md)。
本轮已核实 Qwen 的 `v0.2.38` 与追加工作日志，并在 `10610845`、`0d494317` 修补
图集完整性、请求重放、恢复收据校验和动图跨圈暂停问题；完整主线 CI `36182275763` 通过。
`v0.2.39` / build `50` 已于北京时间 2026-09-26 05:11:31 正式发布，标签 CI `36186415604`
全部通过，六资产、旧公钥验签、匿名更新源及完整公开 DMG 校验通过，详见上述记录。
本轮发版已完成；不要重建或移动同版本标签，下次发版仍须先协调唯一负责人并核实实际远端状态。
新增解析、真实浏览器重放和收据回归位于 `test_kuaishou_album_integrity.py`、
`test_kuaishou_request_replay.py`、`test_kuaishou_resume_fingerprints.py`，均在正式 helper 测试目录。
旧恢复记录缺少摘要或签名 URL 变化时会保守重新下载，不覆盖旧文件；不能恢复“不从头读主页”的错误承诺。
整主页全量、明确末页和真实图集仍未完整验收。软件解码／渲染回归不能替代 M4 Max 硬件验证。

**以下为历史 review，需先对照上述新记录：**
[`Codex 评审后的修补与验收清单`](handoffs/2026-09-25-glm-fix-guidance.md)。
文件名保留历史称呼。其中 R1–R7 给出复现条件、修补要求和验收证据；基于 `7372e9cb`，不是已修复声明。
GLM 后续已提交 `662d5a0e`，必须先核实最新分支和差异，不照着旧清单重复覆盖修补。

HDR 默认关闭改动见 [PR #1](https://github.com/SeanLi-Coder/ChengYingPlayer/pull/1) 及
[`HDR 交接`](handoffs/2026-09-25-hdr-default-off.md)。该 PR 已在本轮合入主线；
保留用户明确保存的开关偏好，实体 HDR 屏幕表现仍需在目标机器验证。

快手视频、图片/图集和 Chrome Cookie 脱敏诊断的完整需求、实现范围、测试结果、真实站点阻塞和 review 清单见：

[`docs/handoffs/2026-09-25-kuaishou-codex-review.md`](handoffs/2026-09-25-kuaishou-codex-review.md)。

Codex review 前先确认当前 `main` 包含 `ca14c85e`，并重新核对公开 release 状态；不要把快手真实主页尚未通过登录态验收写成已完成。


> 请先阅读根目录 AGENTS.md、docs/AI_COLLABORATION.md 和
> Tools/DownloaderHelper/UPSTREAM.md，确认当前分支与现有改动。
> 这台 M4 Max 用于验证另一台机器无法访问的站点，请在正式播放器下载中心继续开发，
> 不要恢复已取消的独立快手测试包。先提出与你收到的具体任务对应的验证计划，
> 完成后交回提交／PR、准确测试结果及未验证项。
