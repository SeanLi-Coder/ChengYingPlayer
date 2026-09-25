# 给 GLM：快手评审后的修补与验收清单

用户已要求把 Codex 的评审结论写入仓库，供 M4 Max 上的 GLM 读取。
**本次提交只包含指导文档，不代表下列问题已经修复。**

- 评审基线：`1ae999d9`；被评审版本：`7372e9cb`。
- 范围：正式播放器的快手解析、图片／图集下载、恢复、Chrome Cookie 诊断及相关测试。
- 阅读顺序：根目录 `AGENTS.md` → `docs/AI_COLLABORATION.md` → 本文 →
  `Tools/DownloaderHelper/UPSTREAM.md`。旧的
  [GLM 交接记录](2026-09-25-kuaishou-codex-review.md) 是历史实现说明，不是已通过本轮验收的证明。
- 先检查当前分支、HEAD、工作树和后续提交。如果问题已被别人修复，核实对应回归后再标完成，
  不重复覆盖。使用独立功能分支，不恢复用户已取消的独立快手 ZIP／测试包。
- 下文行号来自被评审版本，仅用于定位；函数名和现有源码是准绳。

## 一、先建立失败回归，再修代码

建议顺序：R1／R2 修解析语义 → R3／R4 修下载与恢复 → R5／R6 修诊断链路 →
R7 补验证和来源记录。不要用删除断言、降低画质门槛、关闭证书检查或扩大可信域名来消除失败。
每项均应给出“修复前能复现、修复后通过”的证据。

### R1 · P1：不要把视频误判成图片，也不要把封面当完整作品

位置：`Tools/DownloaderHelper/vendor/rednote/app/kuaishou.py`
的 `parse_video`（约 305、414 行）与 `_image_assets`（约 258 行）。

已用同一合成输入对比基线与当前代码：

| 输入 | 被评审版本的错误结果 | 应有结果 |
| --- | --- | --- |
| 有效 1920×1080 视频 manifest，另有对象列表形式的 `photoUrls` | 变成 `image`，甚至没有可下载资产 | 保留视频类型及可核实的视频候选 |
| 声明时长 5000 ms，无视频流，只有带尺寸的 `coverUrl` | 把封面当图片作品，主页解析可报告完整 | 缺少真正作品媒体，明确失败或不完整，不能用封面兜底 |
| 单张图片使用 `photoUrl` 对象 | 可能被当成无尺寸视频 | 仅在具有可靠图片类型／结构证据时按单图处理；否则明确不支持 |

修补要求：

- `photoUrl`／`photoUrls` 是对象或列表，不足以证明作品是图片。
  明确媒体类型、实际视频流和经过核实的图片结构不能被这条启发式覆盖。
- 不以“没有解析出视频流”推断“这是图片”。`coverUrl` 不能作为缺失视频的替代成品。
- 保留作品 ID、作者 ID、可信 HTTPS 目标和完整性检查。无法核实的条目不得当作完成。
- 给上述三种输入加入解析回归，再覆盖主页包含此类条目时的整体完成状态。

### R2 · P1：图集逐张保留，不能只保留整组像素最大的图

位置：同文件 `_image_assets`（约 254–281 行）。

合成输入中，两张不同图片分别为 800×600 和 1600×1200，当前只留下第二张；
主页却仍可能标记完整。原因是把所有图片混成一个候选池，再做一次全局最大像素筛选。

修补要求：

- 明确区分“图集中的不同图片”与“同一图片的不同清晰度／备用地址”。
  先按站点可靠结构建立图片身份和顺序，再在每一张图内部选择最高可核实档位。
- 不根据 URL 文件名或尺寸相近程度猜测两条记录是同一张图。
  若真实返回结构无法区分，应报不支持／不完整，不能静默丢掉条目。
- 有一张缺少身份、尺寸或有效媒体时，不能删掉它之后仍报告整组完成。
- 在 M4 Max 获取用户授权范围内的真实结构证据，但只保留脱敏结构和合成 fixture，
  不把原始页面、Cookie、签名媒体地址或个人图片提交到 GitHub。

至少加入以下测试：不同尺寸的多张图片全部保留；每张各有多个档位；同档备用地址；
顺序稳定；重复记录；中间一张无尺寸；其中一条实际为视频封面；已验证图集与正常视频共存。
真实站点尚未验证的结构必须注明，不能用自行构造的 schema 冒充已适配。

### R3 · P1：视频候选应择一下载，不能当成多个图集成员

位置：`Tools/DownloaderHelper/vendor/rednote/app/downloader.py`
的 `_download_kuaishou_item`（约 5417–5426 行）。

当前对所有 `video.assets` 循环，每次只把 `[asset]` 传给
`_download_first_available_asset`。用同一视频的 H.264 与 HEVC 两个最高尺寸候选复现：

- 两个候选都可用时，下载流程返回两个成品，而不是一个视频。
- 第一个候选失败、第二个可用时，流程直接失败，第二个没有被尝试。

修补要求：

- 视频与图集使用不同的资产集合语义：视频传入已完成画质筛选的候选集合，
  成功一个即结束；图集对每张图片分别选择和下载。
- 保留同最高档候选／备用地址的既有尝试策略，不引入静默降到低清的兜底。
- 不改变现有应立即停止的认证、证书、取消等错误语义；不要无差别吞掉所有失败。
- 测试两个候选都成功时只有一个输出、第一个普通传输失败时第二个可尝试、
  所有候选失败、取消、低档候选不得被使用。

调用链测试可以用合成返回值核实候选分组，但它不证明实际传输、画质校验或文件写入成功；
另需本地 HTTP fixture 与真实媒体文件的传输回归。

### R4 · P2：图集每完成一张就记录，失败／重启后能正确恢复

位置：同函数约 5425–5430 行；同时检查 `task_manager.py` 的事件处理与恢复逻辑。

当前只有全部图片成功后才发出 `asset_completed`。模拟第一张成功落盘、第二张失败时，
第一张文件存在，但整个过程没有一次 `asset_completed` 事件，任务记录不知道它已完成。
当前重名避让又会生成新后缀，重试存在重复下载已完成图片的风险。

修补要求：

- 每张图片通过实际校验并原子落盘后，及时提交该图片的完成记录。
  任务记录应能关联作品、图片身份／顺序及可核实的本地文件，不能只依赖文件名。
- 只提前发事件仍不够：确认重试、进程重启和重新解析后确实读取、校验并复用已有记录。
- 源图片或顺序变化时不错误复用；用户修改的文件不覆盖；缺失文件可重新下载。
- 测试第二张失败、第二张下载前取消、第一张成功后进程重启、重复标题与已有同名用户文件。
  断言磁盘文件和持久化任务状态，而不只断言内存中的事件列表。
- 失败不能假报整组完成，已成功文件不能因后续失败被删掉。

### R5 · P2：把 Cookie 诊断接到快手实际路径和中文界面

位置：

- `app/kuaishou.py` 的 `_browser_cookies` 异常分支（约 599–603 行）；
- `app/douyin_signing.py` 的 Cookie 诊断调用及异常封装；
- `app/static/app.js` 的 `localizeRuntimeMessage`／`composeIssueMessage`（约 1113 行）。

上述 `app/` 均指 `Tools/DownloaderHelper/vendor/rednote/app/`。

已确认的两处断点：新增诊断只接入抖音，没有接入快手；即使抖音产生诊断后缀，
前端也会把整句换成固定中文，从而丢失数据库锁定、权限等具体类别。

修补要求：

- 快手实际 Cookie 提取失败的分支也必须生成安全分类，保留 `cookie_unavailable` 的错误语义。
- 优先使用白名单化的结构化诊断字段贯穿异常、事件／任务状态、API 和 UI；
  如兼容现有字符串方案，也必须严格只接受已知安全码，不能回显任意原始异常后缀。
- 中文界面分别说明权限、数据库锁定、解密、Profile 缺失等问题，并给出对应操作建议。
  不把所有问题都归因为“请退出 Chrome”，不把打开设置当作已授权成功。
- 覆盖分类函数 → 快手／抖音实际调用 → 状态/API → 真实前端格式化的整条链。
  仅手工构造一个包含诊断后缀的异常再断言字符串，不足以证明功能可用。
- 全程用合成异常、虚构 Profile 和临时文件测试，不读取真实用户 Cookie。
  断言结果不含 Cookie 值、完整路径、代理密码、token 或原始异常内容。

### R6 · P2：诊断辅助函数不能掩盖原始 Cookie 错误

位置：`app/browser.py` 的 `chrome_cookie_diagnostic`（约 67–80 行）。

当 Cookie 提取失败，同时诊断中的目录／数据库探测抛出 `OSError` 时，当前异常会逃出辅助函数，
在抖音实际签名调用链中使原本的 `cookie_unavailable` 变成 `site_response_changed`。
这不是站点结构真的变化；快手尚未接入该诊断的问题另见 R5。

修补要求：对诊断过程本身的预期文件系统错误提供安全兜底，例如固定的
`cookie_access_unknown`，保留原业务错误分类；不泄漏底层异常，不吞掉取消／退出控制信号。
增加合成 `PermissionError`、数据库锁定、解密错误、目录检查 I/O 错误与数据库检查错误回归，
并通过实际签名／发现调用链确认最终错误类别，而不是只调用诊断函数。

### R7 · 测试质量、来源记录与 CI 收尾

- `test_kuaishou_output_directory_is_separate` 当前只是比较两个手写 `Path`，
  并未调用任务管理器。改为验证真实生产路径计算、持久化结果及旧任务恢复。
- 原最高视频尺寸测试的独立函数名被移除，但断言仍嵌在另一个测试中。
  可恢复清晰的测试划分，不要误以为断言已全部删除；新增图集负例不能只增加通过数量。
- `UPSTREAM.md` 尚未补齐 `browser.py`、`douyin_signing.py` 及诊断测试的补丁说明。
  同步文档、manifest、校验器的实际范围；原始 `upstream_sha256`、许可证和来源不能改写。
  其中关于 `test_stop.py` 是唯一上游测试改动的描述也需同步，不把旧的测试基线冒充新结果。
- 每个实际 vendor 文件改动后，只更新对应集成哈希并核对差异，不通过重写全部哈希掩盖改动。
- 旧 handoff 的重复短链标识文字曾触发 Spelling 误报。本次文档提交删除该重复行、
  保留原链接；后续仍需核对 CI，不要关闭拼写检查、排除整个文档目录或改坏真实标识。

## 二、最低验收命令与证据

依赖安装和开发／发行环境隔离见 `docs/AI_COLLABORATION.md`。在已配置的测试环境、
仓库根目录运行，缺少依赖时记录原因，不把跳过当通过：

```bash
python Tools/DownloaderHelper/verify_vendor.py
python -m ruff check Tools/DownloaderHelper --exclude vendor
python -m pytest -q -rs Tools/DownloaderHelper/tests/test_kuaishou.py Tools/DownloaderHelper/tests/test_kuaishou_frontend.py
python -m pytest -q -rs Tools/DownloaderHelper/tests
python Tools/DownloaderHelper/run_upstream_tests.py
node Tools/DownloaderProxyUITests/main.mjs
bash Tools/DownloadCenterTests/run.sh
python -B Tools/SparkleUpdateTests/test_release_policy.py
python -B Tools/SparkleUpdateTests/test_release_delivery.py
git diff --check
```

如果增加了新的测试文件，确认它被上述目录级测试或 CI 收录，不只手工运行一次。
用本地临时媒体、HTTP 服务和独立临时浏览器配置测试，不碰真实任务数据。
站点字段解析用合成 fixture；媒体完整性用真实文件和 FFprobe／图片解码器；
恢复用持久化记录及重启；UI 用实际格式化函数／界面。

注意测试名称也可能误导：`test_browser_profile_real_pagination_observation` 当前使用模拟浏览器，
不能当作真实主页证据；`test_checked_route_real_chrome_*` 使用真实 Chrome 和本地服务，
也不能当作快手登录／图集／主页已经验收。图片验证需要完整解码，不能只信文件头宽高。

在 `7372e9cb` 上，Codex 重跑结果是：vendor 校验通过；helper **321 项测试和 62 项子测试通过**；
隔离上游 **1382 项通过**；发布策略 19 项、交付策略 15 项通过。
**这些是修补前的基线，不是上面问题已解决的证据。**
R1–R6 的补充合成案例说明现有绿灯存在覆盖缺口。记录新的失败／通过／跳过数量及准确命令。
发布策略及交付策略测试属于离线验证，不等同于本轮实际安装、重启或完整 DMG 下载验证。

## 三、M4 Max 现场验收与发布边界

本机没有完成目标站点的真实登录态全量下载验收。M4 Max 应在用户明确授权的账号、
链接和网络下，先核对单视频、单图、多图集，再验证主页混合内容、明确分页结束、
最高返回档位、真实文件参数、取消／重启恢复。认证失败或 `result=109` 应记录为阻碍，不能绕过。

保留既有可信域名／逐跳重定向、TLS、账号身份、代理、画质、原子写入及取消机制。
交接文档里的合成例子不授权扩大抓取范围，也不授权发布私人现场数据。
真实返回结构与当前假设不一致时明确报告并补适配，不编造作品数或“全部完成”。

评审时的 GitHub 记录表明 `v0.2.36` 已发布，但 `ca14c85e` Cookie 诊断在其后，
尚未随该标签发布；本次评审没有重新下载完整 DMG。开始工作时重新检查版本、标签和 CI，
不能只看 `main` 就认为用户安装版已有对应功能。

按根 `AGENTS.md` 的既有约定完成验证和正式发布，由双方约定的一方负责版本与标签，
避免并行发版。不覆盖 `v0.2.36` 附件、不移动旧标签、不绕过失败门禁；
保留旧版可用的更新身份、签名、用户设置和模型。修补涉及业务代码，不能以本次“纯文档”
提交为理由省略后续版本递增、完整 CI、签名更新与公开交付检查。

## 四、交回结果时逐项填写

```text
Base / final commit:
Branch / PR:
R1: fixed / not fixed / no longer reproducible, evidence
R2: fixed / not fixed / no longer reproducible, evidence
R3: fixed / not fixed / no longer reproducible, evidence
R4: fixed / not fixed / no longer reproducible, evidence
R5: fixed / not fixed / no longer reproducible, evidence
R6: fixed / not fixed / no longer reproducible, evidence
R7: tests, provenance and CI outcomes
Tests: exact commands, passed / failed / skipped counts
Live verification: performed / blocked / not performed, sanitized results
Remaining risks:
Release: not released / draft / published, verification limits
```

不要只回复“测试全过”或“全部修好”。提供对应提交与证据，未修、未实测、未发布分别列明。
