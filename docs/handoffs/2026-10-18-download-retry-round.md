# 下载失败续队、一次补试与逐项复制链接

## 范围

- 基线：`9b0f3a5d`，稳定播放器 `v0.2.84` / build `95`。
- 分支：`codex/download-retry-round`；正式版本 `v0.2.85` / build `96`。
- 本轮唯一发布者：Codex；提交 `16377403e91cb2d1fb3619fc305bcd5b285798db` 已合入主线并发布。
- 不合入已暂停的原生播放内核实验，不改播放依赖、媒体原件、模型、系统权限或账号配置。

## 行为

- 单项可恢复网络／服务故障先持久化并显示，后面的作品继续处理；首轮结束后对当前提交范围的合格失败项补试一轮。
- 不递归创建新任务，不无限重试，不重复下载完成项；仍失败的保留原因与继续入口。
- 显式继续沿用原任务的账号、输出目录、素材校验与无覆盖规则。重启不会自动执行旧任务。
- 登录、验证码、限流、不可信目标或配置问题保留原暂停门禁，取消优先。
- 每项提供规范作品网页链接的主动复制；不以作者主页、临时 CDN 地址或含凭据链接替代。
- 剪贴板写入失败时给出可选中的文本与手动复制方式，不谎报复制成功。
- 新轮次字段兼容缺少该字段的旧记录；脱敏诊断只新增固定补试事件名，不记录链接或账号资料。

## 验收与限制

以下本机检查已通过，完整 App 按既定流程仅在 CI 构建；正式发布证据见下节。

- `Tools/DownloaderHelper/verify_vendor.py`：69 个原导入文件及集成清单完整性通过；仅更新本轮五个已审核补丁的集成散列，不改变原始上游散列。
- `python -B Tools/DownloaderHelper/run_upstream_tests.py`：隔离临时副本、禁止外网，1,405 passed。
- `CHENGYING_REQUIRE_CHROME_UI=1 python -B -m pytest -q -rs Tools/DownloaderHelper/tests`：1,431 passed、65 subtests passed、无跳过；包括 46 个新增队列案例以及真实隔离 Chrome 的复制／手动回退／SSE／版本门禁测试。
- `python -m ruff check Tools/DownloaderHelper --exclude vendor`、`git diff --check`：通过。
- `Tools/DownloaderProxyUITests/main.mjs`：63 checks；Chrome Profile UI：51；脱敏诊断 UI：55；输出目录索引：1,538。
- 下载 helper 的协议、鉴权、代理持久化、锁、重启与 EOF smoke 通过；总结 helper 的 URL、脱敏、隔离 smoke 通过。
- `bash Tools/DownloadCenterTests/run.sh`：runner 3 tests，原生 WebKit 英文／简中各 304 checks，拥有的临时 App 已精确注销并移除。
- 自动更新策略 19 tests、发行交付 20、增量 14、基线 16、测试工作区 36 加单独 LaunchServices 集成 1、公开工作区 11、原生 updater runner 7 通过。
- `bash Tools/AppUpdateTests/run.sh`：143 checks；`bash Tools/SparkleUpdateTests/run.sh`：23 tests，包含实际隔离签名／安装正反例，清理通过。
- 独立只读复核未发现剩余阻断项；原生 helper 显式启用新策略，standalone 默认暂停规则不变。

实现中曾发现抖音的 `TemporaryAccessError` 传输失败路径会提前中断整队列，已在受控临时故障范围内接入续队／补试，并保留来源刷新、限流、身份及安全门禁。最终失败类别按仍未完成的条目重算，避免恢复成功后显示旧错误。

本轮不读取真实 Chrome Cookie，不对用户历史主页发起额外下载；离线状态机和界面验证不等同于网站全量下载验收。

## 正式发布与更新交付

- [v0.2.85 正式发行](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.85)：北京时间 **2026-10-18 03:15:59** 公开，非 draft、非 prerelease。
- [主线 CI 39058076819](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/39058076819)：成功；完整构建和媒体回归通过，普通主线发布 job 按设计跳过。
- [标签 CI 39058081787](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/39058081787)：媒体回归、Apple Silicon 完整构建、正式发布三个 job 全部成功。
- 完整构建包含真实 4K 渲染／窗口关闭重开、缩放平移、打包 App 快速旋转预览、签名更新正反例、真实更新安装与重启；旧版信任身份不变。
- 增量还原与完整包的签名 App 一致性通过；六个基础资产及增量／校验和共八项在 draft 中完整校验后才公开，未覆盖任何旧标签或已发布资产。
- 发布 job `117480385902` 于北京时间 **03:16:06** 确认未登录的 latest、已安装 App 固定 feed 和匿名下载的完整／增量载荷均与验证产物一致。
- 完整 DMG：`169056021` bytes；SHA-256 `1c8fe9ae082973d4f74fa587cfcaaf04b43f49699881df30a74bc5122c9dd98a`。
- build `95 → 96` 增量：`1021222` bytes；SHA-256 `e2a0a6e06114590f12030765343aed0d4a8f5366cc049a6ae527823638c6a393`。
- 本机已安装 App、用户下载历史、配置、模型及媒体未替换或迁移；本轮仅上传受审核源码和正式发行产物。
