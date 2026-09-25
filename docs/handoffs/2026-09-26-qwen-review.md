# Qwen 提交复核与 v0.2.39 发布交接

## 范围与基线

- 用户要求：审查另一台机器的最新提交和记录；可以修复问题，通过验证后发布。
- 最新主线基线：`0ce26618`；前一正式版本：`v0.2.38` / build `49`。
- 本轮分支：`codex/qwen-review`。已合入原 HDR / Qwen 文档分支，不覆盖主线的新提交。
- 原 GLM 工作日志继续保留历史归属。最新追加记录位于
  [`快手工作日志`](2026-09-25-glm-kuaishou-worklog.md)，不能只按文件名判断记录是否为旧内容。

## 已核实的交付和限制

v0.2.38 的 tag 工作流 `36168070575` 三个作业均成功，包含前稳定版公钥验签、
真实更新安装及篡改拒绝、六项发布资产和完整匿名 DMG 下载校验。
本机重新获取公开 feed 并以 v0.2.36 公钥验签通过；这一轮没有重新下载旧版完整 DMG。
旧工作日志里的 `test_release_delivery.py` 本身是离线模拟回归，打印的上传及验证信息
不是实际远端资产证据；实际 v0.2.38 交付证据来自上述 tag 工作流。

另一台机器记录了单视频和主页三条抽样实测、文件参数、完整解码及任务恢复对照。
这是协作者的现场记录，不是本机重新执行的快手下载。整主页全量下载、明确末页以及
真实图片／图集结构仍未完整验收，不能因为离线测试通过就标为“全部下载完成”。

## 本轮审查发现与处理

1. 图集存在不可验证成员或超过保护上限时，原代码可能静默丢成员后报告完整。
   新回归要求整组明确不完整；同图最高尺寸的备用 URL 应保留，不能被丢掉。
   Apollo 列表也不能先截断后仍沿用末页标记。
2. 文件恢复只按作品和位置、尺寸及可解码性判断，不足以识别同尺寸替换或图片调序。
   恢复必须核对本地文件内容与媒体来源指纹，不存储签名 URL 原文，不覆盖旧文件。
   URL 或来源信息变化、旧记录缺少校验证据时，允许保守重新下载，不宣称永远零请求复用。
3. 中断后的“继续任务”会重新读取主页；仅本次浏览器会话内的退避重试才沿用当前游标。
   已修正文案和实际前端回归，去掉跨任务“不从头读取”的错误承诺。
4. 合入默认关闭 HDR：保留显式保存的开启／关闭偏好及手动开关，不改源文件。
   修正新增测试中触发拼写检查的拼接字面量，不放宽拼写门禁。
5. Python Playwright 的空参数会回继原请求：POST 重定向为 GET 后原正文可能再次发送；
   过滤后为空的请求头可能重新带出认证信息，HEAD 303 也被误转为 GET。
   已用真实 Chrome 和本地 HTTP 服务复现并修正，不放宽可信域、TLS 或逐跳检查。
6. 追查前一版图片 UI 偶发失败，确定性复现有限循环动图在异步跨圈换帧时暂停，
   会提前消费圈数，恢复后少播一圈。非末圈现在只在新首帧成功提交时计数；取消或过期
   回调不计数，最后一圈正常停止及完整重播语义保留。使用受控解码队列验证真实生产逻辑，
   不用删除断言或增加任意等待来让旧失败消失。

## 本机最终回归

下列 `python` 使用已安装项目锁定依赖的隔离测试环境。媒体使用合成文件，浏览器使用
新的临时 Context；未访问用户 Chrome Profile、Cookie 或私人媒体。

| 命令 | 结果 |
| --- | --- |
| `python Tools/DownloaderHelper/verify_vendor.py` | 通过，仅更新四个实际改动文件的集成摘要，原始上游摘要不变 |
| `python -m ruff check Tools/DownloaderHelper --exclude vendor` | 通过 |
| `python -m pytest -q -rs Tools/DownloaderHelper/tests` | 509 passed，62 subtests passed，0 skipped |
| `python Tools/DownloaderHelper/run_upstream_tests.py` | 1405 passed，隔离源码与外网禁用 |
| `node Tools/DownloaderProxyUITests/main.mjs` | 63 checks |
| `bash Tools/DownloadCenterTests/run.sh` | 227 checks，含真实 WebKit 本地交互 |
| `bash Tools/HDRPreferenceTests/run.sh` | 42 checks，含独立进程偏好读取和 Intel 类型检查 |
| `bash Tools/SimplificationTests/run.sh` | 144 checks |
| `bash Tools/PreferenceSearchTests/run.sh` | 11 checks |
| `bash Tools/ICCProfileTests/run.sh` | 6161 checks，12 次真实离屏渲染；计数随像素差异变化 |
| `bash Tools/ImageViewerUITests/run.sh` | 142 UI + 52 真实图片后端 checks，macOS 10.15 Intel 类型检查通过；新跨圈取消回归修补前失败、修补后通过 |
| `bash Tools/ImageSlideshowUITests/run.sh` | 120 checks |
| `bash Tools/SparkleUpdateTests/run.sh` | 16 项签名 feed／DMG 测试通过，使用临时测试密钥 |
| `bash Tools/AppUpdateTests/run.sh` | 131 checks |
| `bash Tools/UpdateActivityTests/run.sh` | 49 activity + 24 helper drain checks |
| `python -B Tools/AppUpdateIntegrationTests/run.py` | 临时 App 真实替换、可见进度和重启通过 |
| 上述命令加 `--scenario tampered-dmg` | 等长篡改包被拒绝，旧 App 未变、没有重启 |
| `python -B Tools/SparkleUpdateTests/test_release_policy.py` | 19 passed |
| `python -B Tools/SparkleUpdateTests/test_release_delivery.py` | 15 passed，离线回归 |
| `typos .`（CI 同版本 1.50.2）及 `git diff --check` | 通过 |

Sparkle 相关命令使用本机已有的固定 2.10.0 artifact 设置 `SPARKLE_TEST_ROOT` 或
`SPARKLE_FRAMEWORK_DIR`，具体变量见各测试目录的 README。实际发行 App 的嵌入组件仍需 CI 验证。

新增 36 项 helper 回归覆盖：23 项解析／请求重放和 13 项收据／恢复。
其中真实 Chrome + loopback 重放测试已运行；不是快手在线验收。
未验证的 HDR 实体屏幕画面、真实图集和完整主页继续保留为限制。

## 发布状态

已准备 `0.2.39` / build `50`，尚未创建标签或发布。由本轮 Codex 负责后续整合与发布，
避免另一台机器同时创建同版本标签。必须先通过本轮代码回归及完整 CI，之后沿用既有
签名身份、更新源和六资产发布流程；发布完成前不能称已安装播放器已获得这些修复。
