# Instagram v0.2.65 review：Qwen 修补与验收清单

## 接手范围与基线

- 用户于 2026-10-06 要求 Codex 审查 Qwen 已发布的 Instagram 功能，随后要求将建议
  写进合作文档，由用户交给 M4 Max 上的 Qwen 修复。本次只提交文档，不修改功能、不发版。
- 审查基线：`v0.2.65` / build `76`，标签对应提交
  `e3eca8cfdba1a22591fe85137fbf473f2a00a914`。下文行号均针对该提交；
  接手时先 fetch 并核对最新源码，不能把基线问题无条件认定为后来版本仍存在。
- 先完整阅读 `AGENTS.md`、`docs/AI_COLLABORATION.md` 与
  `Tools/DownloaderHelper/UPSTREAM.md`，保留其他人未提交的工作。
- 历史实现及 Qwen 的实站记录见
  [Instagram 主页批量下载交接](2026-10-06-instagram-profile-downloads.md)。
  下面七项是待修问题，不是已修声明，也不表示历史正常下载结果无效。
- 本机 review 未读取真实浏览器 Cookie，未重新下载目标主页。复现使用合成数据、
  临时目录、回环 HTTP 及隔离 Chrome；真实站点异常是否发生需另行验证。
  临时复现没有作为新增回归提交：Qwen 需要把用例落实到正式测试中。

## 优先级与状态

所有项目在审查基线均为 **open**。建议先修 R4 的出站限制，再修 R1/R2 的文件正确性，
随后处理 R3/R5/R6 的完整性和 R7 的诊断；这是推荐顺序，不要求改变模块所有权。

| ID | 优先级 | 已确认问题 | 主要位置 |
| --- | --- | --- | --- |
| R1 | P1 | 源内容改变后，重试能把旧断点与新内容拼接并报告完成 | `downloader.py:1211,4640,4849` |
| R2 | P1 | 视频分支缺少实际作品／作者和落地媒体验证 | `downloader.py:1202–1218` |
| R3 | P1 | 相册成员解析失败后静默漏项，仍可报告完整 | `instagram.py:584–590,1063–1068` |
| R4 | P1 | 跨域重定向请求已经发出，之后才报“已阻止” | `instagram.py:1243–1258` |
| R5 | P2 | 分页不验证游标连续性，缺页也能报告完整 | `instagram.py:791–802,833–838` |
| R6 | P2 | 空末页的结束证据被丢弃，正常结束被判未完成 | `instagram.py:797–799` |
| R7 | P2 | 登录、验证、网络过滤等诊断异常被捕获范围吞掉 | `instagram.py:1510–1524` |

上述文件均位于 `Tools/DownloaderHelper/vendor/rednote/app/`。
下文 English 测试名是建议新增的用例，不是声称仓库中已经存在。

## R1：断点恢复必须绑定源内容

**证据：** Instagram 视频直接进入通用 yt-dlp 分支，该路径启用 `continuedl`，失败时保留
`.part`，但没有可靠的源内容身份绑定。真实 yt-dlp 加回环 HTTP 的复现中，首传中断留下
64,512 字节 A；新 downloader 重试得到另一签名地址及不同的同长度源 B，总长 262,144
字节。服务器收到 `Range: bytes=64512-`，最终输出由 64,512 字节 A 与 197,632 字节 B
拼接，却仍标记完成。

**限定：** 本次同时改变了 URL 和源字节，不能写成“仅 URL 换签名就一定损坏”。
64,512 是观测值，不应写死为跨平台断言；源字节不变时续传可能正确，但当前路径缺少证明。

**修补与回归要求：**

- 没有可靠源身份依据时保守重新完整下载；若保留恢复功能，须验证本地断点与远端源内容
  属于同一版本。文件名、总长度、作品 ID 或 URL 相同本身都不能单独证明内容一致。
- 新建 downloader 模拟重启：同作品、标题、文件名，首次传输中断；第二次返回不同源 B，
  保留真实 yt-dlp 传输、生产暂存／发布路径及回调，不 mock 掉恢复逻辑。
- 成功输出须与完整 B 一致；失败不得发布混合文件或发出 `completed`。
  同时覆盖源不变、服务器忽略 Range、长度变化、取消与重启恢复。
- 不覆盖已有用户文件；只清理本任务拥有的临时文件，不删除未知旧任务数据。
- 建议用例：`test_instagram_retry_does_not_splice_changed_source_bytes`、
  `test_instagram_retry_reuses_partial_only_with_verified_source_identity`。

## R2：视频在传输前核对身份，发布前验证媒体

**证据：** 现有 `1202–1205` 只比较队列自己的 URL 与存储的 shortcode，不是核对实际
extractor 返回结果；`1211` 的视频提前返回，绕过后面的作者检查。通用路径未为 Instagram
应用作品／作者门禁，发布前也未完成实际视频参数校验。
仅替换 extractor 输出、保留真实 yt-dlp 传输和原子发布的隔离复现中，另一作品／作者的
结果配合 50 字节非视频响应，仍发布 `.mp4`、发出 `completed`，并显示声明的 1080×1920。

**修补与回归要求：**

- 分别构造身份错配与媒体无效用例，避免一个失败条件掩盖另一个：
  身份错配配正常合成视频；身份匹配配 `Content-Type: video/mp4` 但正文为非视频的响应。
- 传输前核对实际作品与作者身份，不能只比较队列字段。缺少必要身份不能静默当作匹配；
  正常的相册父帖／子部件标识应做显式规范化，不能把二者差异直接误判为另一作品。
- 发布前核验实际媒体类型、合理时长、选定档位尺寸及需要保留的音轨。
  另覆盖声明尺寸与真实尺寸不一致、截断文件和音视频合流；无效结果不得正式发布或计成功。
- 只有提取结果／已选音视频轨明确应有声音时才要求对应音轨，不能误伤合法无声视频。
  FFprobe 可解析不等于全文件解码通过，也不等于取得作者原始最高画质。
- 保留代理、取消、最高可验证档位、文件不覆盖及清理边界。
- 建议用例：`test_instagram_video_rejects_resolved_identity_mismatch`、
  `test_instagram_video_rejects_invalid_media_before_publication`、
  `test_instagram_video_preserves_expected_audio_stream`。

实际丢音或真实站点作者错配未在本轮实测；对应要求是补齐回归，不是声称已经发生。

## R3：相册失败成员不能从统计中消失

**证据：** `parse_work` 只保留 `_part_from_node` 成功构造的成员；剩一个成员就接受整贴，
collector 只在整贴解析失败时记录问题。合成一篇两张图的相册，第二张
`image_versions2.candidates=[]`，得到：

```text
complete=True
declared_count=1
parts=1
problem_count=0
warning=None
```

总帖数完全一致，因此帖子数量警告也无法发现这张漏图。pipeline 相册入口同样静默跳过。

**修补与回归要求：**

- 保留逐成员失败／未验证状态和原始位置，核对声明成员数、收到的成员数及有效成员数。
  不因重排而改变任务部件身份，不用封面代替视频，不把解析失败当作不存在。
- 覆盖中间成员无候选、缺少尺寸、缺少身份、全成员无效以及混合图／视频相册。
  同时覆盖网页发现和单帖 pipeline 两个入口。
- 已成功成员仍可保留并下载；UI 和队列必须显示剩余问题，不能把部分成功写成全部完成。
  重试后恢复缺失成员，不能覆盖或重复计数已完成输出。
- 建议用例：`test_instagram_carousel_retains_unresolved_parts`、
  `test_instagram_pipeline_carousel_reports_partial_media`。

## R4：重定向必须在目标收到请求之前拦截

**证据：** `check_redirect_target` 是 `request` 事件观察者，只向 `errors` 加异常，
不能阻止已经发生的请求。调用生产 `_discover_profile`，使用真实隔离 Chrome 和两个
回环 origin；测试中将 URL／host 与主页身份判定适配为合成 fixture，保留真实路由和
事件处理逻辑：302 导航目标确实收到 GET；
可信页的 POST 经 307 后，不可信目标收到原始合成 POST 正文，随后程序才抛异常。
没有使用真实 Cookie 或秘密，不能据此宣称真实凭据已泄漏，但“请求前阻断”保证已被反例推翻。
现有测试只检查最终抛异常，不能证明目标没有收到请求。

**修补与回归要求：**

- 在每个目标实际收到请求前执行拦截；仅监听 `request`、`framenavigated` 或事后关闭页面
  都不足以作为证明。保持生产 HTTPS、可信域名及跨域认证边界，不能扩白名单让测试通过。
- 选择能兼顾真实 Instagram 前端加载的实现。不要机械恢复已被 Qwen 实站测出停载的全量
  `route.fetch()`／`fulfill()` 中继；也不要为了加载正常撤掉安全约束。
- 用真实浏览器、双回环服务器记录目标请求数，断言不可信目标收到 **零个请求**，
  而不只是最后发现失败。覆盖 301/302/303/307/308、导航与子请求、GET/HEAD/POST。
- 可信跳正常完成；POST 转 GET、HEAD、正文及认证头的语义正确；代理出错不直连，
  取消有界。回环 HTTP 例外只能存在于 fixture，不能进入生产 URL 规则。
- M4 Max 补充真实目标主页枚举，确认修复未恢复“加载停住、没有时间线”的旧问题。
- 建议用例：`test_instagram_redirect_is_blocked_before_target_receives_request`、
  `test_instagram_trusted_redirect_preserves_request_semantics`。

## R5：完整枚举必须有连续分页证据

**证据：** 目前只排除重复 request cursor，没有核对它与上一页 `end_cursor` 的关系。
第一页返回 `end_cursor="required-next"`；下一响应使用
`cursor="skipped-page-cursor"` 并声明末页，仍得到两篇作品、`complete=True`、无警告。

**修补与回归要求：**

- 分开维护“已收到的 request cursor”与“下一步期望的 end_cursor”，避免将下一页游标
  提前加入去重集合后误丢合法页。必要时有界缓冲乱序响应并恢复连续链。
- 首包、完整连续链和明确末页必须属于同一作者与本轮枚举；丢中间页、陌生游标、循环、
  重复响应及旧轮次响应均不得凭最后一包直接宣称全量完成。
- 已验证作品可以保留为部分结果；给出可继续／重试提示，不能因为缺页删掉已下载文件。
  进度分母要区分“当前发现部件已处理完”和“整个主页完整下载完”。
- 建议用例：`test_instagram_profile_requires_contiguous_cursors`、
  `test_instagram_profile_handles_out_of_order_pages_without_false_completion`。

## R6：处理空末页，但不能放宽 R5

**证据：** `accept` 在查看 `page_info` 前对空 nodes 直接返回。
首包一篇、`has_next_page=True`；对应下一游标返回 `edges=[]`、`has_next_page=False`，
结果却是 `complete=False`、`terminal=False`、`pages=1`。

**修补与回归要求：**

- 对身份与连续游标已核实的空末页保留明确结束证据，即使没有新增作品也可正确结束。
- 陌生游标、结构不合法、授权错误或仍有下一页的空响应不能当作完成。
  测试合法零作品主页、合法空末页、空中间页及空错误响应。
- 建议用例：`test_instagram_profile_accepts_verified_empty_terminal_page`。

## R7：只捕获 DOM 读取错误，不吞业务异常

**证据：** 两段 `contextlib.suppress(Exception)` 同时包住浏览器读取与业务分类／抛错。
分别提供明确的 `Domain blocked` 标题、`Please log in to continue` 对话框、
`Please complete checkpoint verification` 提示，函数都返回 None，未抛预期分类异常。

**修补与回归要求：**

- 将 DOM 读取错误的容错与业务分类分离。读取成功后在捕获范围之外抛出登录、验证、
  限流、网络过滤等明确异常，并确认上层 UI 显示对应可操作提示。
- DOM 节点失效等读取错误仍能合理处理；任意帖子正文／评论中的类似词不能误判为站点阻拦。
  保留取消优先级，不用广义异常捕获将用户取消变成站点故障。
- 建议用例：`test_instagram_visible_block_preserves_classified_error`、
  `test_instagram_visible_block_ignores_caption_text`。

## 测试证据与修补后的提交要求

下面是 **本次 review 已执行的基线检查**，不是新增七项回归，也不是修补后成绩。
在仓库管理的现有开发环境中运行以下命令，`python` 指该环境解释器：

```sh
python Tools/DownloaderHelper/verify_vendor.py
python -m pytest -q -rs Tools/DownloaderHelper/tests/test_instagram.py Tools/DownloaderHelper/tests/test_vendor.py
python -m ruff check Tools/DownloaderHelper --exclude vendor
CHENGYING_REQUIRE_CHROME_UI=1 python -m pytest -q -rs Tools/DownloaderHelper/tests
python Tools/DownloaderHelper/run_upstream_tests.py
node Tools/DownloaderProxyUITests/main.mjs
node Tools/DownloaderDiagnosticsUITests/main.mjs
```

结果：vendor 完整性通过；专项加 vendor 测试 91 passed、3 subtests passed；Ruff 通过；
完整 helper 1141 passed、65 subtests passed；保留上游测试 1405 passed；代理 UI 63 项、
诊断 UI 55 项通过。这说明已有门禁没有覆盖这些异常，不应删除或削弱原有测试。

Qwen 修补后请逐项填写 R1–R7 的状态、修复提交、正式回归用例、准确命令与通过／失败／
跳过数量；无法解决的明确列为未解决，不只写“所有测试通过”。至少做到：

1. 将隔离用例提交进正式测试，确认基线失败、修复后通过；真实网络限制不能用全 mock
   代替请求／传输边界的验证。浏览器 fixture 不读取真实账号，结束后关闭服务与进程。
2. 按 `UPSTREAM.md` 只更新实际变更文件的集成摘要，保留来源、许可证和原始摘要；
   不覆盖 Qwen 其他工作，不修改无关播放／HDR／剪辑代码，不重建独立测试下载包。
3. 运行完整 helper、上游、原生下载中心以及所改 UI 的回归；覆盖小红书、抖音、快手、
   B站、YouTube 原有路径，不把对 Instagram 的修补扩大成无依据的平台降级。
4. 在用户授权的登录态／代理和原目标主页范围内补充 M4 Max 实测：枚举完整性、混合相册、
   实际媒体参数与播放、取消重启和单项失败恢复。不得换用其他账号或抓取其他内容。
   公开记录只放计数、参数、诊断类别和结论，不提交媒体、Cookie、原始网页或签名 URL。
5. 区分离线验证、真实站点验证和正式发布。协调唯一发布负责人，使用更高版本及 build，
   不覆盖 v0.2.65 的标签或资产；保留自动更新、完整包回退、用户配置与模型。

## 已发布版本的独立复核

`v0.2.65` 于北京时间 **2026-10-06 16:10:18** 正式发布。
[正式 Release](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.65)、
[主线 CI](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/37428729996)、
[标签 CI](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/37428820796) 已核实。
主线、标签及拼写检查成功，8 项资产齐全。新增 freetype 下载回退相关测试 37/37 通过。

本机匿名核对 latest 网页指向 v0.2.65；实际客户端 feed 与精确版本 feed 逐字相同，
使用此前独立可信 plist 的公钥验签通过。完整下载并验证：

| 归档 | 字节数 | SHA-256 |
| --- | --- | --- |
| 完整 DMG | 168929036 | `1421eff22150a5e37d9da10d7f3fb8951f98db7c187193de24178c345e1d92a5` |
| from-build-75 增量 | 1193258 | `6dae6a201fde30f694f81ebb7ddb556dd13413fb54246ddd43ba43244cacdf10` |

两者公开 checksum 与 Ed25519 验签通过。本机匿名 REST API 限流，latest 采用匿名网页
重定向核实，不将限流当作产品失败。本轮未挂载／安装 App，未再次实际应用 delta；
真实签名安装、增量全树还原、损坏回退与配置模型保留依据已核实的标签 CI 成功记录。
已清理本轮临时下载；未更改用户正式 App、账号或下载目录。

发布交付正常与功能异常仍然存在是两个独立结论。历史文档中的“尚待发布验收”已过时；
不能据此重建同一版本，也不能用交付检查成功替代 R1–R7 的修补。
