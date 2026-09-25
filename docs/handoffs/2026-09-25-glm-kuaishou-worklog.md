# 快手评审修补工作日志（GLM / M4 Max）

供 Codex 审查。本文件持续追加，记录实际操作、验证证据与未验证项。

- 日期：2026-09-25
- 仓库：`SeanLi-Coder/ChengYingPlayer`
- 基线：`6e8e396a docs: hand off Kuaishou review fixes to GLM`
- 分支：`glm/kuaishou-review-fixes`
- 评审依据：`docs/handoffs/2026-09-25-glm-fix-guidance.md`（R1–R7）
- 语言约定：代码、标识符、提交信息、日志用 English；本文件用中文。
- 脱敏约定：不含 Cookie 值、token、签名媒体 URL、作品 ID 具体值、标题原文、
  原始网页或个人媒体。

---

## 0. 环境与方法

- 测试环境：`.build/glm-tests`（Python 3.13.15，Playwright 1.62.0，既有环境，未重建）
- 运行时可用：`node v20.11.1`、`ffmpeg`、`ffprobe`、Google Chrome（`/Applications`）
- 每项修补均按指引要求先建立**失败回归**，再修实现，并保留"修复前失败 /
  修复后通过"证据。取证方式：把对应 vendor 文件临时换回 `git show HEAD:` 的
  原始版本，运行新增测试或行为探针，记录结果后立即从备份恢复，并用
  `verify_vendor.py` 与哈希比对确认恢复无误。

---

## 1. R1 · 媒体类型误判（P1）— 已修

**问题**：`image_hint` 仅凭 `photoUrl`/`photoUrls` 是"对象或列表"就把作品判为图片；
"没解析出视频流"会被推断为图片；`coverUrl` 可被当作作品兜底。

**实现**（`vendor/rednote/app/kuaishou.py`）：
- 新增 `_structured_image_groups()`：以**字段基数**（而非 URL 文件名或尺寸相近度）
  判定图片身份与顺序。`photoUrls`（复数列表）= 有序图集；`photoUrl`（单数）= 单图，
  其列表形式为该图的多档变体。
- `parse_video()` 改为：可核实的视频流（`selected`）优先返回；其次才看图片证据；
  两者皆无 → `assets=[]` 的 unsupported，**不用 `coverUrl` 兜底**。
- `coverUrl` 不再作为图片来源读取。

**修复前失败证据**（原始 `kuaishou.py` 上运行新增测试）：
```
FAILED test_valid_video_with_object_photo_urls_stays_a_video
FAILED test_sized_cover_only_post_is_not_an_image_work
FAILED test_album_keeps_every_distinct_image_in_declared_order
FAILED test_album_selects_highest_variant_within_each_image
FAILED test_album_member_without_dimensions_makes_album_unsupported
FAILED test_album_cover_entry_is_not_image_evidence
FAILED test_profile_with_unsized_album_member_is_not_complete
FAILED test_profile_with_verified_album_and_video_completes
8 failed, 3 passed
```
**修复后**：全部通过。

**真实站点验证**：目标主页 8 页 / 143 条作品，修复后
`media_types={'video':143}`、`without_assets=0`、`parse_errors={}`。
修复前这 143 条会因 `photoUrls` 是字典列表被全部误判为图片、再因条目无宽高
变成 unsupported。

---

## 2. R2 · 图集逐张保留（P1）— 已修

**问题**：原 `_image_assets()` 把所有图片混成一个候选池做**全局最大像素**筛选，
800×600 与 1600×1200 两张图只剩第二张，主页却仍可能报 complete。

**实现**：
- `_image_variants(group)`：在**单张图片内部**选最高可核实档位；无声明尺寸则
  该图不可声称最高质量。
- `_structured_image_groups(photo)`：先建立图片身份与顺序，再逐张建资产。
  图集按页面顺序建立 `asset.index`，`format_id=kuaishou-image-<n>`。
- 任一图片缺可核实尺寸或可信媒体 → `_image_assets()` 返回 `[]`，
  整组报 unsupported，**不静默丢成员后仍报完成**。

**回归**：不同尺寸多图全保留、每张多档、同档备用地址、顺序稳定、重复记录、
中间一张无尺寸、其中一条为视频封面、图集与视频共存、
主页含无尺寸图集成员时 `complete=False` 且 `unsupported=True`。

**未取证**：真实多图图集结构（见第 8 节）。

---

## 3. R3 · 视频候选择一下载（P1）— 已修

**问题**：`_download_kuaishou_item()` 对所有 `video.assets` 循环、每次只传 `[asset]`。
同一视频的 H.264 与 HEVC 两个最高档：都可用时产出**两个文件**；
第一个失败时**不尝试**第二个。

**实现**（`vendor/rednote/app/downloader.py`）：
- 拆分为 `_download_kuaishou_video()` 与 `_download_kuaishou_album()`。
- 视频：把已完成画质筛选的**整个候选集合**一次传入
  `_download_first_available_asset()`，成功一个即结束（复用既有候选重试语义：
  普通传输失败尝试下一个，认证/证书/取消仍立即抛出）。
- 图集：每张图单独选择并下载。

**修复前失败证据**（原始 `downloader.py` 上的行为探针）：
```
parsed renditions: 2
R3 transfer-helper calls: 2  assets per call: [1, 1]
R3 output files: 2
```
**修复后**：`calls=1`、`assets per call=[2]`、`output files=1`。

**回归**：两候选都成功只产一个输出；首个普通传输失败时第二个被尝试
（断言实际请求顺序 `?h264` → `?hevc`）；全部候选失败时报
`All highest-available media URLs failed` 且不降档；取消不残留 `.part`；
另含**本地 HTTP fixture + 真实 JPEG 字节**的传输回归。

---

## 4. R4 · 图集逐张完成记录与恢复（P2）— 已修

**问题**：只有全部图片成功后才发 `asset_completed`；第一张成功、第二张失败时，
文件在盘但**任务记录零事件**，且重名避让会生成新后缀导致重复下载。

**实现**：
- `EngineEvent` 新增 `asset_records` 字段（不含媒体 URL，可安全持久化）。
- `_download_kuaishou_album()`：每张图通过实际校验并原子落盘后**立即**发
  `asset_completed`，携带 `{media_id, index, path, width, height, size, format_id}`。
- `task_manager._on_engine_event()` 把记录白名单化后写入
  `item.metadata["kuaishou_album_assets"]` 并即时持久化。
- `_public_kuaishou_album_record()`：只接受白名单字段，拒绝缺 `media_id`/`index`/
  `path` 的记录，`bool` 不被当作 `int`，额外字段（如 `candidates`）被丢弃。
- `_kuaishou_saved_album_records()`：按**作品身份 + 图片位置**索引，不按文件名。
- `_existing_kuaishou_image_asset()`：复用前必须仍在输出目录内、是真实文件而非
  符号链接、**通过完整解码校验**、且不低于声明尺寸；否则重新下载。
- `_decode_local_image()`：用 FFmpeg 完整解码（新增 `FFMPEG_FALLBACK_PATHS` 与
  `_find_ffmpeg_executable()`）。仅信文件头宽高不够。

**修复前失败证据**（原始代码探针，第一张成功、第二张 503）：
```
R4 asset_completed events: 0
R4 files actually on disk: ['2026-09-19-Fixture album-001.jpg']
R4 REPRODUCED: a saved file was never reported as completed
```
**修复后**：`events: 1`、`records carried: [1]`。

**完整解码校验的区分能力**（实测）：
```
blue-1600x1200.jpg -> exit=0  stderr_bytes=0
truncated.jpg      -> exit=69 stderr_bytes=1250   # 截断文件仍报合法文件头尺寸
```

**回归**：第二张失败时第一张已记录；下载前取消保留第一张且无 `.part`；
成功后重启复用第一张、只请求第二张、不产生新后缀；记录缺失身份/位置被拒绝；
其他作品的记录不被复用；截断/移出目录/缺失文件均不复用。

---

## 5. R5 · Cookie 诊断接入快手与中文界面（P2）— 已修

**问题**：新增诊断只接入抖音、未接入快手；前端会把带诊断后缀的整句换成
固定中文，丢失具体类别。

**实现**：
- `browser.py`：新增 `COOKIE_DIAGNOSTIC_CODES` 白名单与
  `public_cookie_diagnostic_code()`（未知值一律回落 `cookie_access_unknown`，
  绝不回显任意原始异常后缀）。
- `kuaishou._browser_cookies()`：异常分支生成安全分类，保留 `cookie_unavailable`
  语义并附 `Diagnostic: <code>.`，同时携带结构化 `diagnostic_code`；
  取消与解释器退出信号先于分类重新抛出。
- `douyin_signing._CookieAccessSigningFailure` 新增 `cookie_diagnostic_code`；
  `_cookie_diagnostic_of()` 优先结构化字段、回退严格白名单解析。
- `models.py`：`DownloadItem`/`DownloadJob` 新增 `diagnostic_code` 字段。
- `task_manager.py`：`_record_issue_locked()` 只接受白名单内的 Cookie 类别
  （抖音签名码不会被误判为 Cookie 类别）；所有状态重置点同步清空；
  `_backfill_job_issue_locked()` 让旧持久化任务也能从文本恢复类别；
  抖音两处刷新失败包装点改为**保留** Cookie 类别，不再重标为签名完整性失败。
- `static/app.js`：八个类别各有独立中文说明与操作建议；标题改为
  `Chrome Cookie 读取失败：<具体原因>`；旧任务只有文本时也能恢复类别；
  快手 Cookie 文案不再一律"退出 Chrome"。

**修复前失败证据**：`test_signing_diagnostics.py` 新增用例在原始代码上
`11 failed`；行为探针显示
`R5 structured diagnostic_code: None`、`R5 message contains category: False`。
**修复后**：探针显示
`structured diagnostic_code: cookie_permission_denied`、`contains category: True`。

**回归**：分类函数 → 快手实际调用 → 抖音签名链 → 任务状态/API → 真实前端格式化
（用 `run_ui()` 实际执行 `app.js`）整条链；恶意值与未知值一律被丢弃；
断言结果不含 Cookie 值、完整路径、token 或原始异常文本。

---

## 6. R6 · 诊断辅助函数不掩盖原始 Cookie 错误（P2）— 已修

**问题**：`chrome_cookie_diagnostic()` 探测目录/数据库抛 `OSError` 时异常逃出，
使原本的 `cookie_unavailable` 变成 `site_response_changed`。

**实现**：文件系统探测包在 `try/except OSError` 内，失败返回固定
`cookie_access_unknown`；**只捕获 `OSError`**，`KeyboardInterrupt`/`SystemExit`
仍传播。

**修复前失败证据**（探针）：
```
R6 REPRODUCED: diagnostic helper raised PermissionError operation not permitted
```
**修复后**：`R6 diagnostic returned: cookie_access_unknown`。

**回归**：合成 `PermissionError`、数据库锁定、解密错误、目录检查与数据库检查
I/O 错误；`KeyboardInterrupt`/`SystemExit` 不被吞；各文件系统类别仍可达且不泄露
路径；Profile 名非法被拒；返回值必在白名单内。

---

## 7. R7 · 测试质量、来源记录与 CI 收尾 — 大部分已修

- `test_kuaishou_output_directory_is_separate` 原本只比较两个手写 `Path`。
  现新增 `platform_output_directory()`（`downloader.py`）作为**唯一**生产路径
  计算，`task_manager.py` 两处重复逻辑改为调用它；测试改为验证真实生产路径、
  持久化结果、重启后旧任务保留目录，并新增作者名越权防护参数化用例
  （`../../escape`、`/absolute/name`、`..`、`a/b\c`、空白）。
- 原最高视频尺寸测试的函数名曾被删除、断言残留在另一测试体内成为**死代码**
  （永不执行）。已恢复为独立函数
  `test_highest_video_size_rendition_is_selected_and_low_rendition_excluded`。
- `UPSTREAM.md`：补齐 `browser.py`、`douyin_signing.py` 与诊断测试的补丁说明；
  修正"`tests/test_stop.py` 是唯一上游测试改动"的过时表述为
  "`test_stop.py` 与 `test_signing_diagnostics.py` 是两个被改动的上游测试文件"；
  补充图集/中断/诊断的边界说明。
- `upstream-manifest.json`：只更新实际改动文件的哈希
  （`files[].vendored_sha256` 与 `integration_files[].sha256`），
  **未改写任何 `upstream_sha256`**、未扩大忽略列表、未批量重写哈希；
  同步更新 `allowed_patches` 说明以反映实际范围。
- `git diff --check`：无空白问题（曾出现一处 EOF 空行，已修）。
- **待办**：Spelling CI 需在推送后核对，不关闭拼写检查、不排除整个文档目录。

---

## 8. 真实站点验收（本机，Chrome `Default` 登录态，直连）

### 8.1 单视频 — 通过（含端到端下载与续传）

发现层：
```
target: https://www.kuaishou.com/f/X1MM7OtmlFNd11q  -> ('short_link', ...)
login mode: chrome-cookie(Default)   proxy mode: direct
OK in 1.8s
  source_kind=item  complete=True  warning=no
  items=1  by_type={'video': 1}
  media_type=video  assets=1  sizes=[(720, 1280)]  date=2026-09-24
  distinct_author_ids=1  items_without_assets=0
```
匿名模式下同一链接返回
`Kuaishou returned no verified video data`（`SITE_RESPONSE_CHANGED`），
即需要登录态；这不是代码缺陷，如实记录。

端到端下载（走生产 `download_item` 链路，输出目录 `<tmp>/Kuaishou/<作者名>/`）：
```
discovery: items=1 complete=True media_type=VIDEO date=2026-09-24
download:  OK in 4.4s  resolution=720x1280  selected_format=kuaishou-1  files=1
filename:  2026-09-24-<标题（已脱敏）>.mp4     date_prefixed=True
measured:  video_codec=h264 audio_codec=aac width=720 height=1280
           duration_s=43.13 size_bytes=13697992
full_decode: exit=0 stderr_bytes=0            # FFmpeg 完整解码通过
```
文件名格式与用户要求一致（`2026-09-19-#平底鞋给不了高跟鞋的优雅 #家纺人聊睡眠.mp4`
这种日期开头 + 标题 + `#话题` 形态）。标题与作者名属用户内容，本文档不记录原文。

### 8.2 断点续传 — 通过（真实任务管理器流程 + 反向对照）

先说明一个**探针假象**：直接调用 `downloader.download_item` 时，第二次运行会产生
带 `[media_id]` 后缀的重复文件。原因是完成记录由 `task_manager` 持久化后回传，
绕过任务管理器就等于绕过记录，**不是产品缺陷**。经真实流程确认：
已完成条目调用 `retry_item` 会被 `ItemNotRetryableError` 拒绝，不会重复下载。

真实流程验收（`DownloadManager` + 持久化 state + 统计引擎实际媒体请求数）：
```
=== first run ===
  status=completed files=1 fetches=1 persisted_records=1  record_kinds=['video']
=== simulate interruption AFTER the file landed ===
  item=failed job=interrupted  records_kept_through_interruption=1
=== retry the interrupted work ===
  status=completed files=1 fetches=0        # 复用已验证文件，零媒体请求
  file list unchanged (no duplicate): True
  no media re-download:               True
  task recovered to completed:        True
=== negative control: delete the file, then retry ===
  status=completed files=1 fetches=1
  a missing file IS re-downloaded:    True
```
反向对照证明"0 次请求"是复用生效，而非什么都没做；文件被删除后确实会重新下载。

### 8.3 主页 — 发现并修复两个真实缺陷

内存内用生产解析器处理真实响应（被动观察，不经生产路由拦截）：
```
captured feed pages: 8
per-page items: 23,20,20,20,20,20,20,(result=2, 0 items)
total items across pages: 143
media_types: {'video': 143}
asset_stats: {'with_assets': 143, 'without_assets': 0}
parse_errors: {}
distinct sizes observed: [(576,1024), (720,1280), (720,1284)]
```

#### 缺陷 A（严重，阻断性）：页面静态资源域名不在浏览器白名单

**现象**：生产 `discover()` 对同一主页返回
`SITE_RESPONSE_CHANGED` / "no verified video data"，而被动观察能抓到 143 条。

**定位过程**：对生产路径插桩统计路由与采集器调用：
```
total routed requests: 4
feed/profile routes: 1 (document /profile/<id>)
routes that raised: 0
collector.accept calls: 0        # feed 响应从未到达解析
non-1 result payloads seen: 0    # 与限流无关
```
再做一次主机普查（复现生产白名单判定），结论明确：
```
ABORTED load-bearing (script/stylesheet/xhr/fetch/document): 66
  p5-plat.wskwai.com   script ×8,  stylesheet ×7
  p23-plat.wskwai.com  script ×1,  stylesheet ×7
  p66-plat.wskwai.com  script ×3,  stylesheet ×3
  p4/p5-plat.wsbkwai.com ...
feed requests seen: 0
BROWSER_DOMAINS 原值: ('kwaicdn.com','ksyuncdn.com','ksapisrv.com','yximgs.com',
                       'kwimgs.com','kuaishou.com','gifshow.com','gifshowstatic.com')
```
真实主页的 JS/CSS 由快手官方静态资源 CDN `wskwai.com` / `wsbkwai.com` 提供，
这两个根域**不在白名单**，全部 66 个 script/stylesheet 被 `route.abort()` 拦截
→ 页面 JS 从未执行 → **站点自己的 `/rest/v/profile/feed` 请求从未发出**
→ 采集器 0 次调用 → 报"没有可验证数据"。

这正是 `docs/AI_COLLABORATION.md` 第 4 节预警的风险点：
"CSS/JS 请求失败……是否能给出脱敏、可操作的诊断，而不是只显示'没有发现作品'"。

**修复**（`app/kuaishou.py`）：新增 `STATIC_ASSET_DOMAINS = ("wskwai.com","wsbkwai.com")`
并仅并入 `BROWSER_DOMAINS`（浏览器页面子资源白名单）。
**严格不放宽的两处**：`MEDIA_DOMAINS`（媒体下载来源）与 `PAGE_HOSTS`
（页面导航身份）均未改动，媒体完整性校验强度不变。

**修复前后对比（真实站点，同一主页、同一登录态、直连）**：
```
修复前: BLOCKED  issue=SITE_RESPONSE_CHANGED   items=0
修复后: OK in 27.9s  source_kind=profile  items=183  by_type={'video':183}
        distinct_author_ids=1  items_without_assets=0  complete=False(限流)
```
183 条比被动观察的 143 条更多，因为修复后页面 JS 正常运行、
生产路径自身的退避重试也生效了。多条作品 `assets=2`（同尺寸 H.264/HEVC 双档），
正是 R3 要求"择一下载"的真实场景。

**失败回归证据**（临时撤销该白名单，测试文件不动）：
```
FAILED test_page_static_asset_hosts_are_routable_but_never_media_hosts[p5-plat.wskwai.com]
FAILED test_page_static_asset_hosts_are_routable_but_never_media_hosts[p66-plat.wskwai.com]
FAILED test_page_static_asset_hosts_are_routable_but_never_media_hosts[p4-plat.wsbkwai.com]
FAILED test_static_asset_domains_do_not_widen_page_or_media_allowlists
4 failed, 4 passed
```
恢复修复后 8 passed。新增回归同时锁住**反向不变量**：这些域名
`not in MEDIA_DOMAINS`、`not in PAGE_HOSTS`、`is_media_url()` 为 False，
并覆盖 `wskwai.com.evil.test`、`evilwskwai.com`、`not-wsbkwai.com`、
`p5-plat.wskwai.com.evil.test` 等仿冒域名仍被拒绝。
修复后已用 `shasum` 与 `grep` 确认无临时改动残留、哈希与清单一致。

#### 缺陷 B：限流时丢弃已验证作品

**现象**：生产采集器 `complete=False`，因为某页返回
`{"result":2,"error_msg":...}` → 分类 `REQUEST_REJECTED` → `observe()` 收进
`errors` → 主循环 `raise errors[0]` → **已验证的 143 条全部丢弃**。

**三次独立抓取分别在第 8、3、1 页出现该响应** ⇒ 间歇性限流，**不是终止信号**
（真实终止信号 `pcursor=="no_more"` 从未出现）。

修复后该情形被正确识别为可恢复中断：报错文案由误导性的
"returned no verified video data" 变为
"stopped serving the author feed before any work could be verified …
Reason category: request_rejected."（本轮实测触发，见 9.1）。处理见第 9 节。

#### 主页端到端下载抽样 — 通过

修复缺陷 A 后，通过生产链路对主页抽样下载 3 条（限流期间
`discovery_complete=False`，警告带 `Reason category: request_rejected.`，
已验证作品仍全部保留入队）：
```
3 files, all status=ok, all media_type=VIDEO
dir_relative: Kuaishou/<作者名>          # 独立目录，作者名已脱敏
starts_with_date: true (all 3)
measured (FFprobe): 720x1280 h264, durations 51.95s / 54.12s / 29.13s,
                    sizes 17325869 / 19300803 / 9200629 bytes
full decode check: exit=0, stderr=0 bytes for all 3 files
filenames: 2025-08-10-<标题>.mp4 / 2025-09-17-<标题>.mp4 / 2025-08-16-<标题>.mp4
```
三条日期分别取自各作品真实 `upload_date`（非同日），证明日期前缀取自站点数据；
标题与作者名属用户内容，本文档不记录原文。
未做全量 183 条下载：体积较大且本机限流已加重，按"先抽样验证链路、
再由用户决定全量范围"的原则执行。

### 8.4 已取证的真实字段结构（脱敏）

```
POST /rest/v/profile/feed   请求键: [page, pcursor, user_id]
响应键: [feeds, host-name, llsid, pcursor, result, webPageArea]
feed 条目键: [author, comment, danmakuSwitch, photo, tags, type]
photo 键: [animatedCoverUrl, caption, collectCount, collected, coverUrl,
           disableSensitivePhoto, duration, expTag, height, id, likeCount, liked,
           manifest, manifestH265, photoH265Urls, photoUrls, profileUserTopPhoto,
           riskTagContent, riskTagUrl, stereoType, timestamp, viewCount, width]
manifest 键: [adaptationSet, audioFeature, businessType, hideAuto,
              manualDefaultSelect, mediaType, playInfo, stereoType, version,
              videoFeature]
photoUrls: 长度 2, 元素类型 dict, 元素键 = ["cdn", "url"]   # 无 width/height
photoH265Urls: 长度 2, 元素类型 dict
photo 顶层存在 width / height
graphql operationNames seen: []      # 该主页走 REST，不走 Apollo SSR
feed.type: 全部为 "1"
```

据此得出并已落实的两条结论：
1. 真实字段名是 **`photoH265Urls`（复数）**；代码原先读的 `photoH265Url`（单数）
   **从未被观察到**，属推测字段。已停止读取该推测字段。
2. 视频作品的 `photoUrls` 是**封面的 CDN 备份**（无尺寸）。因此已收紧：
   视频候选**只**接受 legacy 裸字符串 `photoUrl`，`photoUrls`/`photoH265Urls`
   一律不得成为视频候选，避免把封面当作品下载。

### 8.5 图片/图集结构 — 未取证

按用户要求自行查找图片作品。共尝试 **7 种入口**（首页推荐流、
"图片"/"图集"/"壁纸"关键词搜索、已知短链、Apollo state 扫描、DOM 链接提取、
图片搜索页 `/search/photo` 等），结果：
所有响应 `feed.type` 均为 `"1"`，所有 `photo` 均含 `manifest` + `duration`，
**未观察到任何无 manifest / 无 duration 的条目**，即未找到图片作品。

因此**没有基于猜测修改图片解析规则**。当前实现遵循 fail-closed：
只有**自带声明尺寸**的图片条目才构成图片作品证据；
`photoUrls` 全无尺寸时视为视频封面备份，作品按 unsupported 处理，
不借用作品级 `photo.width/height` 冒充"最高质量图片"。
多图图集若混合"有尺寸/无尺寸"条目，身份不可解析 → 整组报 unsupported，不猜测。

---

## 9. 用户追加需求（本轮实现）

用户要求：限流时**保留作品 + 自动重试 + 报告哪些作品有问题及原因 + 支持断点续传**；
并要求**适配图片作品**。

### 9.1 可恢复中断不再丢弃作品 — 已实现

- 新增 `RECOVERABLE_PROFILE_ISSUES`（`RATE_LIMITED`、`REQUEST_REJECTED`、
  `SITE_UNAVAILABLE`、`NETWORK_ERROR`）。
  **刻意排除** `CONTENT_UNAVAILABLE`（描述单个作品，不是分页中断）与
  `SITE_RESPONSE_CHANGED`（结构变化必须保持响亮）。
- `is_recoverable_profile_interruption()`：仅在**正在分页**时可恢复；
  `AuthenticationRequiredError` 与 `DiscoveryError` 一律不可恢复。
- `observe()` 按此分流：可恢复 → `interruption`，其余 → `errors`。
- 登录、验证码、作者/作品身份不符、安全拦截**仍然致命抛出**，不降级为 incomplete。

### 9.2 会话内有界退避重试 — 已实现

- `PROFILE_RETRY_ATTEMPTS=3`、`PROFILE_RETRY_BASE_SECONDS=5.0`、
  `PROFILE_RETRY_MAX_SECONDS=20.0`（5s → 10s → 20s，总增量 ≤35s）。
- 每次等待前校验剩余 `MAX_BROWSER_SECONDS=300` 预算，不足则直接返回部分结果。
- 等待按 200ms 分片，**每片检查 `should_cancel()`**，取消即时生效。
- 重试从中断处的期望游标继续（`collector.next_cursor` 未推进），
  **不破坏连续分页链**，不会跳到别页或串号。
- 重试成功则继续正常翻页（已加回归验证 `complete=True`、`warning is None`）。

### 9.3 问题报告：哪些作品、什么原因 — 已实现

- `ProfileCollector` 的布尔 `unsupported` 改为 `problem_count` + 有界
  `problems`（`MAX_PROFILE_PROBLEM_DETAILS=20`），并保留 `unsupported` 属性
  以兼容既有语义。
- 固定原因码（不含站点文本）：`no_verifiable_media`、`unsupported_media_type`、
  `queue_limit_reached`、`page_item_limit_reached`。
- **修复了一个取证中发现的真实缺陷**：原 `feeds[:MAX_PROFILE_ITEMS]` 切片会
  **静默丢弃**超出单页上限的条目，既不计数也不报原因。现改为遍历全部条目、
  超限条目计数并报 `page_item_limit_reached`，且**不解析**（保留性能保护）。
- `_profile_problem_summary()`：按原因聚合计数 + 点名前 10 个受影响作品
  （`#位置:作品ID`）+ 说明超出部分"仅计数"；上限外只计数不展开。
- 摘要并入 `Result.warning`，经既有链路到达任务状态与界面。
- `static/app.js` 新增中文本地化：中断原因、重试进度（`第 N/M 次`）、
  被跳过作品数与原因、受影响作品列表、截断说明；未知类别原样显示而非丢弃；
  原因段只解析固定文案区间，**不会**误匹配受影响作品列表里的标识符。
- 顺带移除一条因前置分支而不可达的旧映射，避免死代码。

### 9.4 断点续传 — 分层交付（含明确不做项）

| 层级 | 状态 | 说明 |
| --- | --- | --- |
| 会话内翻页 | 已实现 | 限流后从中断游标继续，不从头重走 |
| 图集级 | 已实现（R4） | 按作品身份+图片位置复用，需完整解码校验 |
| 作品级（重试/重启） | 复用既有 merge | 需补快手专项回归（见第 11 节待办） |
| 单视频文件级 | **待办** | 计划统一完成记录键，视频复用前用 FFprobe 校验 |
| 单文件内 HTTP Range | **不做** | 见下 |
| 游标跨重启持久化 | **不做** | 见下 |

**为什么不做单文件内 Range 续传**：快手媒体地址是签名的、会过期；
中断后重连签名已变，拼接两段来自不同签名的字节可能产生损坏文件，
违反既有约束"恢复任务不能拼接不同版本内容"。
单文件中断的策略是：清理 `.part`、整文件重下、**绝不覆盖已完成文件**。

**为什么不持久化分页游标跨重启续走**：游标是不透明、会过期的站点内部状态；
持久化会引入陈旧状态，且站点要求从空游标开始连续分页，
用旧游标续走会破坏"连续分页链"这一完整性保证。

---

## 10. 测试结果（改动后实测，非预估）

```
python Tools/DownloaderHelper/verify_vendor.py
  Vendored downloader 1.2.23 integrity verified.

python -m ruff check Tools/DownloaderHelper --exclude vendor
  All checks passed!

python -m pytest -q Tools/DownloaderHelper/tests/test_kuaishou.py \
                  Tools/DownloaderHelper/tests/test_kuaishou_frontend.py
  244 passed            （基线 100）

python -m pytest -q Tools/DownloaderHelper/tests
  473 passed, 62 subtests passed      （基线 321 passed, 62 subtests）

python Tools/DownloaderHelper/run_upstream_tests.py
  1405 passed           （Codex 基线 1382）

node Tools/DownloaderProxyUITests/main.mjs
  PASS: 63 proxy UI checks

bash Tools/DownloadCenterTests/run.sh
  Download center checks passed: 227

python -B Tools/SparkleUpdateTests/test_release_policy.py
  Ran 19 tests — OK

python -B Tools/SparkleUpdateTests/test_release_delivery.py
  All six stable draft assets are uploaded and match their local SHA-256 digests.

git diff --check
  no whitespace errors
```

注：`test_release_delivery.py` 校验的是既有草稿资产与本地摘要一致，
**不等于**本轮已完成新版本发布验证。

---

## 11. 待办状态

### 已完成（本轮）

1. ✅ 作品级断点续传的快手专项回归（任务重试/重启后已完成作品跳过、失败作品重试、
   发现不完整时保留未匹配条目）
2. ✅ 单视频文件级完成记录与 FFprobe 校验后复用（含截断/低清/移出目录/缺失均不复用）
3. ✅ 重跑完整回归套件（第 10 节为最终实测数字）
4. ✅ 阻断性缺陷修复：页面静态资源域名 `wskwai.com` / `wsbkwai.com` 并入浏览器白名单
   （见 8.3 缺陷 A），主页由完全不可用恢复为可采集 183 条
5. ✅ 统一完成记录键：`kuaishou_album_assets` → `kuaishou_saved_assets`，
   视频与图片共用并带 `media_kind`；该键未随任何版本发布，无需迁移
6. ✅ **真实站点端到端下载验收**（见 8.1、8.2、8.3）：
   - 单视频：落盘 1 个 mp4、720×1280/h264+aac、43.13s、13697992 bytes、
     完整解码 exit=0、日期开头命名
   - 主页抽样 3 条：全部 ok、独立目录 `Kuaishou/<作者名>/`、日期前缀取自各作品
     真实 `upload_date`、FFprobe 实测 720×1280/h264、三者完整解码 exit=0
   - 断点续传：中断后重试**零媒体请求**且无重复文件，删除文件后确实重下
     （反向对照证明复用生效）

### 尚未完成（勿视为已交付）

1. ⚠️ **图片作品真实验收**：未取证到真实图片/图集作品（见 8.5），
   图片路径仅有合成 fixture 回归，无真实站点证据。已按 fail-closed 实现，
   未基于猜测编写 schema；需要用户提供一个确认是图集的公开链接才能取证。
2. ⚠️ **主页全量 183 条下载未执行**：体积较大且本机限流已加重，
   按"先抽样验证链路、再由用户决定全量范围"处理。全量下载与
   `no_more` 终止证据仍未取得，因此不能声称"主页全部作品已下载"。
3. ⬜ 递增版本、提交推送、打标签触发 release、匿名核实 latest/feed/DMG
4. ⬜ Spelling CI 核对
5. ⬜ 按指引第四节结构补最终交接文档（逐项 R1–R7 结论）

---

## 12. 改动文件清单（截至本次记录）

```
Tools/DownloaderHelper/UPSTREAM.md
Tools/DownloaderHelper/tests/test_kuaishou.py
Tools/DownloaderHelper/tests/test_kuaishou_frontend.py
Tools/DownloaderHelper/upstream-manifest.json
Tools/DownloaderHelper/vendor/rednote/app/browser.py
Tools/DownloaderHelper/vendor/rednote/app/douyin_signing.py
Tools/DownloaderHelper/vendor/rednote/app/downloader.py
Tools/DownloaderHelper/vendor/rednote/app/kuaishou.py
Tools/DownloaderHelper/vendor/rednote/app/models.py
Tools/DownloaderHelper/vendor/rednote/app/static/app.js
Tools/DownloaderHelper/vendor/rednote/app/task_manager.py
Tools/DownloaderHelper/vendor/rednote/tests/test_signing_diagnostics.py
docs/handoffs/2026-09-25-glm-kuaishou-worklog.md   （本文件，新增）
```

未提交项：`.zcode/`（本地工具元数据）与 `.build/`（探针脚本、测试素材、备份、
端到端下载目录）均不提交。

---

## 13. 我自身在过程中写错、已自查纠正的测试（如实记录，避免 Codex 误判为源码缺陷）

1. `test_cover_cdn_backups_are_never_video_candidates`：最初断言 `media_type=="image"`，
   但按 R1，声明了 `duration` 的作品即使只有封面也必须判为 `video` 且无资产
   （不能把封面当作品）。已改为断言 `video` + `assets==[]`。
2. `test_speculative_cover_fields_are_not_read_as_video_candidates`：最初未清空基础
   fixture 自带的 legacy 裸字符串 `photoUrl`，导致 `assets` 非空、与另一测试矛盾。
   已补 `photoUrl=None` 隔离被测字段。
3. 视频复用测试 `test_existing_video_is_reused_only_after_ffprobe_verification`：
   最初用 `[:8000]` 截断，但 720×1280 一秒的 mp4 仅约 2262 字节，等于没截断。
   已改为按实际大小的 1/3 截断，确保文件真损坏。
4. 重启复用测试 `test_completed_video_is_not_downloaded_again_after_restart`：
   最初生成 1 秒视频，而 `feed()` 声明 `duration=5000`（5 秒），FFprobe 时长校验
   正确拒绝复用。已改为生成 5 秒视频，使复用能通过同一道画质门禁。

这四处都是测试预期错误，源码行为正确；均已修正并附失败回归或对照证据。

