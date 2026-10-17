# 下载列表未完成筛选

## 范围与行为

- 基线：`5670edf5`，稳定播放器 `v0.2.85` / build `96`。
- 分支：`codex/download-unfinished-filter`；正式版本 `v0.2.86` / build `97`，本轮唯一发布者为 Codex。
- 实现提交：`d245d1f82a1dd13a43df47a18a9fc213f00f5f5b`，已推送主线和不可变版本标签。
- 右下角“最近任务”增加“全部／未完成”；“下载明细”也提供“未完成”，保留原成功／失败筛选。
- 等待、下载中、重试、失败、取消／中断、待验证和未完整发现的任务应保留在未完成视图。
- 筛选只影响列表显示，不换号、不改选中任务、不触发继续／重试、不删除下载历史或文件。
- SSE／轮询更新后保留当前筛选，完成项自动移出；空状态区分没有历史和没有未完成任务。
- 不合入已暂停的播放内核实验，不改变登录、下载执行、媒体原件或自动更新身份。

## 验证与发布

界面与快照缓存、本机最终完整回归及标签 CI 正式发布验证均已完成。
完整 App 仅由既有 CI 构建；同提交的主线重复流水线在下述记录时尚未整体完成。
本轮不读取真实 Chrome Cookie 或用户下载历史，不新增实站下载；界面验证不代表网站可用性验收。

已完成的本机回归：

- `Tools/SparkleUpdateTests/test_release_policy.py`：19 tests；`test_release_delivery.py`：20；`test_delta_assets.py`：14；`test_release_base.py`：16，通过。
- `test_app_workspace.py`：默认 36 passed、1 optional skipped；随后显式 `CHENGYING_RUN_LAUNCHSERVICES_TESTS=1 ... LaunchServicesIntegrationTests` 1 test 通过，精确注销合成 App。
- `test_public_workspace.py`：11；`Tools/AppUpdateTests/test_runner.py`：7，通过。
- `SPARKLE_TEST_ROOT=.../sdk bash Tools/SparkleUpdateTests/run.sh`：23 tests，真实隔离签名／校验及清理通过。
- `SPARKLE_FRAMEWORK_DIR=.../macos-arm64_x86_64 bash Tools/AppUpdateTests/run.sh`：143 checks 通过，配置迁移／opt-out 保留。
- `Tools/DownloaderProxyUITests/main.mjs`：63 checks；Chrome Profile UI：51；脱敏诊断 UI：55；输出索引：1,538，通过。
- `Tools/DownloaderHelper/smoke_helper.py`：协议、鉴权、代理持久化、隔离、锁、重启与 EOF 检查通过。
- `Tools/SummarySourceTests/smoke_helper.py`：已安装 helper 协议的 URL／脱敏／隔离 smoke 通过。
- 首轮完整 helper 回归：`CHENGYING_REQUIRE_CHROME_UI=1 python -B -m pytest -q -rs Tools/DownloaderHelper/tests`，1,455 passed、65 subtests passed；随后追加的同状态 SSE 计数／发现变化案例包含在独立新 suite 25 passed 中。
- `python -B Tools/DownloaderHelper/run_upstream_tests.py`：隔离副本、禁止外网，1,405 passed。
- `bash Tools/DownloadCenterTests/run.sh`：runner 3 tests，真实原生 WebKit 英文／简中各 304 checks，通过；本轮测试 App 已精确注销与清理。
- 新筛选宽屏／390 px 窄屏合成截图已加载 native `desktop.css` 并目视检查，未溢出或遮挡；无真实账户、外网或下载请求。
- 最终新筛选 suite：`CHENGYING_REQUIRE_CHROME_UI=1 python -B -m pytest -q -rs Tools/DownloaderHelper/tests/test_unfinished_filter_frontend.py`，34 passed、无跳过；其中 9 项是快照缓存确定性回归，不靠计时阈值判断通过。移除缓存命中的内存负对照正确失败。
- 缓存版再次执行原生 WebKit，英文／简中各 304 checks 通过，测试工作区正常清理。
- 最终缓存版完整 helper 回归：1,465 passed、65 subtests passed、无跳过；上游隔离回归再次 1,405 passed；helper 协议 smoke 再次通过。
- `verify_vendor.py`、`ruff check Tools/DownloaderHelper --exclude vendor`、`node --check .../static/app.js` 和 `git diff --check` 通过；仅更新三份已审阅静态文件的集成散列，原始上游散列未变。

独立复核发现首次实现会在每次 SSE 中重复扫描所有完成历史的作品列表。
本机纯判定基准（不含 DOM）100 个任务各 1,000 项约 24 ms，200 个任务各 5,000 项约 241 ms；
这不是网站吞吐或 UI 帧率验收。增加按任务快照对象的弱引用缓存，新的 API／SSE 合并对象自动重新判定，
避免不变历史重复扫描；不持久化缓存，不缓存账号或媒体内容，不忽略状态外的计数／发现变化。
复核缓存后两组首次判定约 29／243 ms，连续 100 次重复判定平均约 0.003 ms；仅为本机纯函数基准，
不声称包含 DOM、网络或整应用的性能倍数。新的同 revision／无 revision 快照也重新判定，旧 revision 拒绝规则不变。

## 正式发布与自动更新交付

- [v0.2.86 正式发行](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.86)：北京时间 **2026-10-18 04:13:21** 公开，非 draft、非 prerelease。
- [标签 CI 39062872505](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/39062872505)：媒体回归、完整 Apple Silicon 构建与正式发布三个 job 全部成功。
- 完整构建覆盖实际视频预览、4K 渲染／窗口关闭重开、缩放平移、签名更新正反例、真实更新安装与重启、打包后 App 循环边界；正式 DMG 校验通过。
- 增量还原与完整包的签名 App 全树一致，旧版公钥和固定更新源连续性通过。六个基础资产及增量／校验和共八项在 draft 中核对完毕后才公开；未修改旧标签或覆盖已公开资产。
- 发布 job `117492845234` 于北京时间 **04:13:24** 确认匿名 latest、实际客户端固定 feed、完整 DMG 与增量包的完整下载大小及 SHA-256 均符合已验证产物。
- 完整 DMG：`169076126` bytes；SHA-256 `cbe25977f6d6878140dee7e6d6fefea2ecb43ab49840996626fe718e7c895946`。
- build `96 → 97` 增量：`872462` bytes；SHA-256 `d528ef65af7ce42062aa09fa3ecd4397a9650065bb4330cfbb35919b700f67e6`。
- [主线 CI 39062872553](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/39062872553) 同提交媒体回归成功，记录时完整构建仍在真实安装测试阶段；没有把重复主线流水线写成已完成。正式发布依据为已完整成功的标签流水线。
- 未替换本机已安装 App，未改用户下载历史、保存目录、账号、模型或媒体；未执行真实网站下载。拥有的本机测试 App 工作区已精确注销并清理，未处理其他历史测试卷。
