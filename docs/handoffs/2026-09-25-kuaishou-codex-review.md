# 快手下载与 Chrome Cookie 诊断交接（供 Codex Review）

后续 Codex 评审已完成；接续修补请先读
[修补与验收清单](2026-09-25-glm-fix-guidance.md)。下文保留当时的实现记录，
不代表已通过该清单中的新增回归或真实站点验收。

- 日期：2026-09-25
- 仓库：`SeanLi-Coder/ChengYingPlayer`
- 当前分支：`main`
- 当前 HEAD：`ca14c85e`
- 语言约定：代码、标识符、提交信息和日志使用 English；本交接说明使用中文。
- 安全约定：本文不包含 Cookie、token、签名媒体 URL、浏览器资料、个人媒体或原始网页。

## 1. 用户需求原文范围

### 快手

用户要求播放器下载中心支持以下快手能力：

1. 单个快手视频下载。
2. 快手博主主页下载全部可验证作品。
3. 主页作品需要支持视频和图片/图集。
4. 视频和图片均使用网站当前会话实际返回且可以核验的最高质量；不能把封面当成视频，不能静默降档。
5. 快手下载单独保存到独立目录。
6. 文件名以日期开头，例如：
   `2026-09-19-#平底鞋给不了高跟鞋的优雅 #家纺人聊睡眠.mp4`
7. 下载过程保留进度、取消、重试、代理、恢复和已完成文件保护。
8. 完成验证后提交、推送并触发 release。

测试输入：

- 主页：`https://www.kuaishou.com/profile/3x62baa74fujidm`
- 单视频：`https://www.kuaishou.com/f/X1MM7OtmlFNd11q`

### Chrome Cookie 诊断

用户后来遇到以下错误：

```text
Chrome Cookie 读取失败
程序无法读取任务绑定的 Chrome Cookie，因此不能可靠确认当前登录权限或最高画质。
```

用户要求增加分层、脱敏的诊断信息，区分数据库锁定、权限、解密、Profile 或数据库不存在等情况。

## 2. 已完成的代码工作

### 2.1 快手目录和文件名

相关提交：`a816f9a2 Add Kuaishou output organization and naming`

- 快手任务目录：`<output_root>/Kuaishou/<author>/`
- 默认文件名从通用格式改为日期开头的人类可读格式。
- 同名文件不覆盖；发生冲突时追加安全化的媒体 ID，必要时继续追加数字后缀。
- 其他平台保留原有文件名行为。

主要位置：

- `Tools/DownloaderHelper/vendor/rednote/app/task_manager.py`
- `Tools/DownloaderHelper/vendor/rednote/app/downloader.py`
- `Tools/DownloaderHelper/tests/test_kuaishou.py`

### 2.2 快手图片/图集模型和下载接入

相关提交：`d87b5c1a Add Kuaishou image and album downloads`

版本：`0.2.36`，build `47`，标签：`v0.2.36`。

实现内容：

- 快手作品模型增加媒体类型标识：`video` / `image`。
- 对页面返回的图片字段尝试识别图片候选和声明宽高。
- 图片候选按声明像素选择最高档；没有可核验尺寸时不声称最高质量。
- 图片任务使用 `MediaType.IMAGE`。
- 多个图片 asset 按稳定顺序分别下载。
- 复用现有 CDN 白名单、逐跳重定向校验、代理、取消、重试、原子写入和实际尺寸校验。
- 视频仍复用 FFprobe、尺寸、文件长度、媒体身份等校验。
- 快手图片/图集继续使用独立目录和日期开头命名。

主要位置：

- `Tools/DownloaderHelper/vendor/rednote/app/kuaishou.py`
- `Tools/DownloaderHelper/vendor/rednote/app/downloader.py`
- `Tools/DownloaderHelper/tests/test_kuaishou.py`
- `Tools/DownloaderHelper/upstream-manifest.json`
- `Tools/DownloaderHelper/verify_vendor.py`

### 2.3 Chrome Cookie 脱敏诊断

相关提交：`ca14c85e Add diagnostic details for Chrome cookie failures`

实现内容：

- 新增 `chrome_cookie_diagnostic()`，只返回固定诊断类别，不返回完整路径、Cookie 值或原始异常。
- 当前诊断类别：
  - `cookie_decryption_failed`
  - `cookie_permission_denied`
  - `cookie_database_locked`
  - `chrome_data_directory_missing`
  - `chrome_profile_invalid`
  - `chrome_profile_missing`
  - `cookie_database_missing`
  - `cookie_access_unknown`
- 抖音签名 Cookie 读取错误现在会把安全诊断类别附加到用户可见错误，例如：

```text
Chrome cookies could not be read ... Diagnostic: cookie_permission_denied.
```

主要位置：

- `Tools/DownloaderHelper/vendor/rednote/app/browser.py`
- `Tools/DownloaderHelper/vendor/rednote/app/douyin_signing.py`
- `Tools/DownloaderHelper/vendor/rednote/tests/test_signing_diagnostics.py`
- `Tools/DownloaderHelper/verify_vendor.py`
- `Tools/DownloaderHelper/upstream-manifest.json`

## 3. 测试结果

### 快手和下载中心

以下是在当前开发环境运行过的结果：

```text
python -m pytest -q -rs Tools/DownloaderHelper/tests/test_kuaishou.py Tools/DownloaderHelper/tests/test_kuaishou_frontend.py
100 passed

python -m pytest -q -rs Tools/DownloaderHelper/tests
321 passed, 62 subtests passed

python Tools/DownloaderHelper/run_upstream_tests.py
1381 passed

python -m ruff check Tools/DownloaderHelper --exclude vendor
All checks passed

python Tools/DownloaderHelper/verify_vendor.py
Vendored downloader 1.2.23 integrity verified.
```

此外，之前已运行：

```text
node Tools/DownloaderProxyUITests/main.mjs
PASS: 63 proxy UI checks
bash Tools/DownloadCenterTests/run.sh
Native Download Center checks passed
```

### Cookie 诊断

```text
python -m pytest -q -rs Tools/DownloaderHelper/vendor/rednote/tests/test_signing_diagnostics.py
All tests passed
```

Cookie 诊断只测试分类和脱敏，不读取或提交真实 Cookie。

## 4. 真实站点验证状态

### 4.1 当前已知事实

在本机直接使用 Python/yt-dlp 读取 Chrome Cookie 时：

- Chrome Profile 路径为：`.../Google/Chrome/Default`
- `Default` Profile 的 Cookie 数据库可以读取。
- 该 Profile 中能读取到快手和抖音的目标站点 Cookie。
- 因此“完全退出 Chrome”不是唯一可能原因；打包 Helper 的运行身份、钥匙串解密、旧任务绑定或 Profile 配置仍需诊断。

### 4.2 快手目标主页当前阻塞

访问目标主页时，页面接口返回：

```text
/rest/v/profile/feed
result: 109
```

这表示站点要求登录或授权，当前匿名/未绑定有效会话无法得到作品列表。因此以下内容尚未取得真实验收证据：

- 主页实际作品总数。
- 连续分页数量和 `no_more` 结束证据。
- 视频/图片/图集的真实比例。
- 每个真实作品的最高视频档或原图尺寸。
- 主页全量成功下载数。

不能把离线 fixture 测试当作真实主页全量验收。

### 4.3 快手单视频当前阻塞

单视频页面同样可能返回登录要求。离线和代码路径已支持单视频，但当前没有该真实 URL 的完整下载文件、FFprobe 参数和播放验收证据。

### 4.4 现阶段正确结论

当前只能声称：

- 快手视频和图片/图集代码路径已实现。
- 离线安全、分页、身份、质量和传输回归已通过。
- 真实目标主页和单视频仍需用户登录态验证。

不能声称“目标主页全部视频和图片已真实下载成功”。

## 5. Codex Review 必查清单

### 5.1 功能正确性

- [ ] `Video.media_type` 的兼容性和持久化迁移是否安全。
- [ ] 图片字段识别不会把视频封面误判为图片作品。
- [ ] 图集候选是否保留页面声明顺序。
- [ ] 图片最高质量是否真正依据宽高/像素和实际文件尺寸，而不是 URL 名称。
- [ ] 视频质量选择是否仍然保留原有分辨率、codec、码率和 FFprobe 门禁。
- [ ] 多图片输出是否每张都执行原子写入、取消检查、大小和文件头检查。
- [ ] 重试/恢复是否会混用不同版本 URL 或覆盖已有文件。
- [ ] 单视频和主页作品是否使用相同的作者/作品身份绑定。
- [ ] `no_more`、连续 cursor、去重、停滞和上限触发时是否正确标记 incomplete。

### 5.2 安全边界

- [ ] 所有图片和视频 URL 仍经过 HTTPS、域名白名单和逐跳重定向验证。
- [ ] 不接受页面推荐、其他作者或跨作品响应。
- [ ] 不关闭 TLS 校验、不绕过验证码、登录、DRM 或权限控制。
- [ ] 不把封面作为视频替代品。
- [ ] 不把无尺寸图片标记为最高质量。
- [ ] 错误信息不包含 Cookie、token、签名媒体 URL、完整用户路径或 HAR 内容。
- [ ] `chrome_cookie_diagnostic()` 的异常分类不会通过字符串泄露敏感底层信息。

### 5.3 manifest 和上游边界

- [ ] `UPSTREAM.md`、`upstream-manifest.json` 和 `verify_vendor.py` 三者一致。
- [ ] 新增 `app/browser.py`、`app/douyin_signing.py`、诊断测试的 patch allowlist 有明确理由。
- [ ] 未修改上游哈希声明 `upstream_sha256`。
- [ ] 没有通过扩大忽略列表或重写全部哈希绕过校验。
- [ ] 相关 License/NOTICE/来源信息保持完整。

### 5.4 测试质量

- [ ] 离线测试同时覆盖视频、单图、图集、无尺寸图片、低质量候选、备用候选、取消和恢复。
- [ ] 真实站点验证与离线 fixture 结果分开记录。
- [ ] 真实验证报告包含登录模式、代理模式、作品/作者身份、分页结束证据和文件参数。
- [ ] 缺少登录或站点返回 `result=109` 时报告为 blocker，不伪造完成率。
- [ ] 全量上游、helper、Proxy UI、Native Download Center 和 vendor 校验都运行过。

## 6. 需要 Codex 重点复核的潜在风险

1. 当前快手真实主页仍被 `result=109` 阻塞，图片字段形状尚未用该真实主页确认。
2. 图片识别逻辑依赖页面返回的字段和宽高；站点 schema 变化时应 fail closed，而不是猜测。
3. 当前版本标签 `v0.2.36` 对应快手图片实现；公开 release 是否已完成必须通过 GitHub Actions 和匿名 release API 重新确认。
4. `ca14c85e` 是后续 Cookie 诊断修复，尚未单独递增版本号或创建 release 标签。
5. 工作区存在未跟踪的 `.zcode/` 目录，属于本地工具元数据，不应提交。
6. Codex review 应先检查当前 `main` 是否已包含 `ca14c85e`，再判断是否需要合并或补丁。

## 7. 推荐的下一步真实验收命令

在用户已登录快手的 Chrome `Default` Profile、且允许读取 Cookie 后，从仓库根目录运行：

```bash
python Tools/DownloaderHelper/verify_vendor.py
python -m pytest -q -rs Tools/DownloaderHelper/tests/test_kuaishou.py Tools/DownloaderHelper/tests/test_kuaishou_frontend.py
python -m pytest -q -rs Tools/DownloaderHelper/tests
python Tools/DownloaderHelper/run_upstream_tests.py
node Tools/DownloaderProxyUITests/main.mjs
bash Tools/DownloadCenterTests/run.sh
```

真实验收必须额外记录：

```text
Profile: Default（只记录名称，不记录 Cookie）
Login mode: Chrome Cookie / anonymous
Proxy mode: direct / configured proxy
Profile discovery: item count, page count, no_more evidence
Media split: video count, image count, album count
Quality: declared and measured dimensions, codec/duration for video
Files: output directory, sanitized names, size and SHA-256
Result: passed / blocked / incomplete with exact reason
```

不要把 Cookie、token、签名 URL、原始网页、真实个人媒体或浏览器资料写入报告。

## 8. 详细数据与现场证据（脱敏）

本章节专门给无法访问快手网络的 Codex 使用。所有数据均来自脱敏日志、合成 fixture 或固定字段统计；没有保存 Cookie 值、token、签名媒体 URL、HAR、原始网页或个人媒体。

### 8.1 目标输入

```text
Profile:
https://www.kuaishou.com/profile/3x62baa74fujidm

Single item:
https://www.kuaishou.com/f/X1MM7OtmlFNd11q
```

目标主页和单视频都必须通过以下身份约束：

```text
page host: www.kuaishou.com
scheme: https
port: omitted or 443
profile id: 3x62baa74fujidm
```

代码将短链解析后的最终作品重新绑定到站点实际返回的作品 ID；不根据短链字符串猜测媒体 ID。

### 8.2 本机真实请求证据

使用 Google Chrome 154.0.8037.58 arm64、headless browser、默认浏览器请求头和直接网络模式观察目标主页。结果如下：

```text
GET https://www.kuaishou.com/profile/3x62baa74fujidm
HTTP status: 200
page title: target author title was returned

POST /rest/v/profile/feed
request body shape:
{"user_id":"<target-profile-id>","pcursor":"","page":"profile"}

response shape:
{"result":109,"error_id":"","loginUrl":"<redacted>"}

GET /rest/v/profile/get
HTTP status: 200
response shape:
{"result":109}
```

`loginUrl` 中包含站点内部跳转地址，未写入仓库或报告。`result=109` 表示当前请求没有获得可验证的作者作品列表，不能据此推断“主页为空”，也不能把推荐内容当作目标作者作品。

单视频短链页面在匿名/无有效站点会话时同样可能返回登录要求或空状态响应；因此本机没有把它伪造为“真实下载已通过”。

### 8.3 Cookie Profile 现场数据

本机 Chrome `chrome://version` 显示：

```text
Chrome version: 154.0.8037.58 (arm64)
Chrome user data root: <user-home>/Library/Application Support/Google/Chrome
Selected profile directory: Default
```

直接使用开发环境的 yt-dlp Cookie reader 读取结果：

```text
profile: Default
cookie database: readable
Kuaishou-domain cookies: 12
Douyin-domain cookies: 73

profile: Profile 3
cookie database: readable
Kuaishou-domain cookies: 0
Douyin-domain cookies: 0

profile: Profile 4
cookie database: readable
Kuaishou-domain cookies: 4
Douyin-domain cookies: 13
```

只记录数量和域名类别，不记录 Cookie 名称、值、有效期或加密内容。对目标快手登录态，当前应优先使用 `Default`，但“能读取 Cookie”不等于站点一定授权了目标主页；仍需实际 feed 响应证明。

### 8.4 Cookie 失败诊断类别

Cookie reader 的底层异常现在映射到固定字符串：

| 类别 | 含义 | 不代表什么 |
| --- | --- | --- |
| `cookie_decryption_failed` | macOS 钥匙串/Chrome 加密值解密失败 | 不代表账号退出 |
| `cookie_permission_denied` | 文件或系统权限拒绝 | 不代表 Chrome 必须重装 |
| `cookie_database_locked` | 数据库被锁或忙 | 不代表站点验证码 |
| `chrome_data_directory_missing` | Chrome 根目录不存在 | 不代表网络不可达 |
| `chrome_profile_invalid` | Profile 参数不符合允许格式 | 不代表 Cookie 过期 |
| `chrome_profile_missing` | 选定 Profile 目录不存在 | 不代表账号退出 |
| `cookie_database_missing` | Profile 下没有 Cookies 数据库 | 不代表站点没有作品 |
| `cookie_access_unknown` | 其他未分类底层错误 | 需要结合本地日志继续定位 |

这些类别禁止包含完整本地路径、Cookie 值、token、钥匙串内容或原始异常堆栈。

### 8.5 快手解析模型的详细字段约定

#### 页面身份

```text
photo.id          -> media_id
author.id         -> author_id
photo.caption     -> title（优先）
photo.originCaption -> title fallback
photo.timestamp   -> upload_date（UTC date）
```

身份校验规则：

- `photo.id` 和 `author.id` 必须符合安全 ID 字符集。
- 单视频必须匹配请求的作品 ID。
- 主页条目必须匹配目标作者 ID。
- 不接受推荐作品、其他作者作品或响应串线。

#### 视频 rendition

当前代码观察这些页面返回容器：

```text
photo.manifest
photo.manifestH265
photo.videoResource
photo.videoResource.h264
photo.videoResource.hevc
photo.videoResource.h265
```

每个 representation 可使用的字段：

```text
url / backupUrl
width / height
fileSize
avgBitrate
videoCodec
id
```

选择顺序：

1. 过滤不在快手 CDN 白名单内的 URL。
2. 按 `width * height` 建立最高分辨率 floor。
3. 丢弃低于最高像素的 rendition。
4. 同分辨率、同 codec 内保留最高 `avgBitrate`。
5. 不把不同 codec 的 bitrate 直接跨 codec 比较。
6. 按页面候选顺序保留备用 URL。
7. 下载后用文件长度、文件头、FFprobe、尺寸、codec、时长等再次核验。
8. 最高档候选全部失败时报告失败，不静默降档。

#### 图片/图集候选

当前扩展尝试读取页面返回的：

```text
photo.photoUrl
photo.photoH265Url
photo.photoUrls
photo.coverUrl
```

图片条目允许的候选形状包括：

```json
{"url":"https://<trusted-kuaishou-cdn>/...","width":1440,"height":1440}
```

或页面返回的 URL 字符串/URL 列表。对图片：

- 只接受可信 HTTPS CDN。
- 必须有可核验的 `width` 和 `height` 才能声称最高质量。
- 按像素面积选择最高尺寸。
- 图集按页面顺序建立 asset index。
- 下载后检查图片文件头、Content-Type 和实际尺寸。
- 没有尺寸信息时不把未知 URL 当成最高质量。
- `coverUrl` 不能替代缺失的视频流。

### 8.6 分页和完整性数据契约

主页分页状态：

```text
initial cursor: ""
next cursor field: pcursor
terminal marker: "no_more"
max pages: 500
max items: 10000
browser wall-clock budget: 300 seconds
stall threshold: 12 no-new-item cycles
```

只有以下条件同时满足时才标记 `complete=True`：

- 页面返回连续 cursor 链；
- 每一页作者 ID 与目标作者一致；
- 作品 ID 去重后没有串线；
- 页面返回明确的 `pcursor == "no_more"`；
- 没有未支持或无法核验的媒体条目；
- 没有触及页面/作品保护上限。

页面停滞、cursor 缺失、响应结构变化、无视频/图片资产、达到上限都必须标记 incomplete 并给出 warning，不能显示“全部完成”。

### 8.7 输出数据契约

```text
<output_root>/Kuaishou/<safe-author-name>/
```

视频示例：

```text
2026-09-19-<safe-title>.mp4
```

图片示例：

```text
2026-09-19-<safe-title>-001.jpg
2026-09-19-<safe-title>-002.jpg
```

同名冲突：

```text
2026-09-19-<safe-title> [<safe-media-id>].mp4
```

所有文件：

- 使用安全化标题，移除路径分隔符和控制字符。
- 不覆盖已有用户文件。
- 使用临时文件 + 原子替换。
- 取消或失败后清理 `.part` 和临时文件。
- 不把下载 URL 写入持久化任务状态。

### 8.8 离线 fixture 的已验证数据

现有快手测试使用合成数据，代表以下情况：

```text
video id: 3xvideo1
profile id: 3xowner1
media host: v1.kwaicdn.com
low rendition: 640x360
high rendition: 1920x1080
high backup: same trusted CDN family
profile pages: 2
first cursor: ""
second cursor: "next"
terminal cursor: "no_more"
```

已覆盖：

- 最高分辨率选择。
- 同 codec 最高 bitrate。
- 未知 codec 不跨 codec 排序。
- 外作者/外作品阻断。
- 连续 cursor、去重和 `no_more`。
- 无明确终页时 incomplete。
- unsupported media 不假报 complete。
- 单视频刷新 URL。
- CDN 重定向安全。
- 取消时无残留文件。
- 图片最高尺寸 fixture。
- 图集 asset index 和输出路径。
- 日期文件名和冲突 ID 后缀。

这些 fixture 不代表目标主页真实作品数量，也不代表真实网站当前 schema 永不变化。

### 8.9 Codex 在无快手网络环境下的 review 方法

Codex 无法访问快手时，应重点做静态和离线审查：

1. 检查 `parse_video()` 对视频/图片的媒体类型分支。
2. 检查 `_download_kuaishou_item()` 是否对每个 asset 单独执行通用传输和校验。
3. 检查 `ProfileCollector` 是否只接受同作者、连续 cursor 和 `no_more`。
4. 检查 manifest、allowlist 和 `verify_vendor.py` 是否同步。
5. 运行所有脱敏 fixture，不要求访问快手。
6. 不要因为本机无法访问快手而放宽 HTTPS、CDN、作者身份或质量校验。
7. 不要把 `result=109`、网络超时或登录失败改成空主页成功。
8. 如果要修改真实站点适配器，先新增脱敏 fixture，再写实现。

Codex 可以将以下证据作为当前网络事实，而不是代码正确性的替代：

```text
live profile feed response: result=109
live profile item count: unknown
live page completion: unverified
live video/image split: unknown
live highest quality: unverified
```

## 9. 交接状态

```text
Base commit: d87b5c1a for Kuaishou feature; ca14c85e for Cookie diagnostics
Current HEAD: ca14c85e
Branch: main
Scope: Kuaishou video/image/album path and Chrome Cookie diagnostic classification
Offline tests: passed as listed above
Live verification: blocked by Kuaishou result=109 login requirement
Release: v0.2.36 tag exists; public release status must be rechecked
Uncommitted source changes: none known; do not add .zcode/
Remaining work: authenticated real-site Kuaishou profile/item acceptance, release verification, Codex review
```
