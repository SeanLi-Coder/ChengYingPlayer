# 下载中心：可复制的脱敏诊断日志

## 范围

- 基线 `75812905` / v0.2.46，分支 `codex/download-diagnostic-log`。
- 用户要求更新后遇到下载问题，能够直接复制日志反馈。本轮仅扩展原生下载中心，不导出播放器原始日志、Chrome 数据或系统日志。
- 目标 v0.2.47 / build 58；初次提交时发布未完成，正式交付结果在核验后追加。

## 使用方式与隐私

下载中心主页点击「诊断日志」，可以先预览、刷新，再点「复制诊断日志」。系统不允许自动复制时，
文本会被选中并提示按 Command+C。读取由用户主动打开或刷新触发；不会自动上传、复制或写出日志文件。

报告范围明确为最近最多十个匿名任务，不冒充只包含当前选中的任务。记录任务阶段、状态、错误类别、
固定异常类型、数值错误码及可信组件／行号；不格式化原始异常、源码行或局部变量，不收集 Cookie、
令牌、代理密码、Chrome Profile 名、URL、作者、标题、下载路径或真实任务 ID。
采集和导出各自使用白名单，不依赖事后正则删秘密。

日志只在本次下载组件进程的有界内存中保留，App 重启后旧任务仅保留安全状态摘要，
不会把当前版本写成旧错误发生时的版本。报告同时提供播放器版本／build、下载引擎版本／build ID、
原生组件源码指纹和基础运行时版本。输出正文为英文，界面说明为中文。

## 代码边界

- `Tools/DownloaderHelper/diagnostic_log.py`：进程内阶段采集、任务关联、异常白名单、限额与报告。
- `diagnostic_identity.py`：构建时产生只包含发行身份的 sealed JSON；运行时不读取私人配置。
- `chrome_cookie_runtime.py`：在异常被脱敏包装前采集有限结构，保留取消与异常传播语义。
- `helper.py` / `host.py`：启动时安装采集，原有 loopback／Host／Origin／会话 Cookie 验证后提供只读报告 API。
- `static/diagnostics.js` / `.css`：独立面板，限定类型、响应和报告字节大小，处理超时、关闭及版本失配。
- `build_helper.sh` / `download_center.spec` / `bundle_smoke.py`：打包身份资源与实际冻结组件隐私自检。
- 诊断功能不修改 vendor 业务逻辑、任务持久化模型、原始 stderr 丢弃策略、账号绑定或下载质量策略。
- 回归期间额外修复 `app/downloader.py` 的既有 FFprobe 输入轮询缺陷；只更新该文件的集成哈希，
  保留原上游哈希、许可证、原测试和媒体质量门禁。

## 回归中确认的既有探测缺陷

首次完整上游回归为 1404 通过、1 失败：分片 MP4 的前缀探测返回 `None`。
该代码和测试与 v0.2.46 相同，旧构建记录也出现过同一失败；原失败未捕获子进程细节，不能断言当次触发原因。
进一步用同一合成 12 秒 MP4 和发行 FFprobe 验证：原方法无延迟约 25 ms 成功；
仅延迟 150 ms 启动时，首次 100 ms 轮询后输入停在 16384 / 262144 字节，随后约 3 秒到期。
同样延迟、单次 `communicate(timeout=3)` 对照约 208 ms 正常结束。

确认的代码问题是 Python 3.13 在 `communicate(input=...)` 超时后再传 `input=None`，
不会继续注册未完成的 stdin 写事件。修复使用 macOS 匿名临时输入文件，同时保留 FFprobe `pipe:0`、
原总期限与取消轮询；不延长超时、不放宽断言。合成子进程覆盖延迟读取、完整输入、取消、真正超时和资源清理。

## 验证入口

```sh
build/player-v29-tests.nD75s9/bin/python -B Tools/DownloaderHelper/verify_vendor.py
PATH="$PWD/deps/executable:$PATH" build/player-v29-tests.nD75s9/bin/python -B -m pytest -q -rs Tools/DownloaderHelper/tests
PATH="$PWD/deps/executable:$PATH" build/player-v29-tests.nD75s9/bin/python -B Tools/DownloaderHelper/run_upstream_tests.py
build/player-v29-tests.nD75s9/bin/python -B -m ruff check Tools/DownloaderHelper --exclude vendor
node Tools/DownloaderDiagnosticsUITests/main.mjs
node Tools/DownloaderProxyUITests/main.mjs
bash Tools/DownloadCenterTests/run.sh
```

- 新面板 Node 55 项通过；真实 WKWebView 英文、中文各 256 项通过，新增 29 项。
- 最终完整 helper 822 项及 62 子测试通过（63.42 秒），完整上游 1405 项通过（69.48 秒），均无跳过。
  新采集器专项 48 项，FFprobe 子进程专项 13 项，身份／API等相关回归另有覆盖。
- 原生更新界面 143 项、签名更新 23 项、发布策略 19 项、交付 20 项、增量资产 14 项通过。
- 首次真实冻结 helper 构建、严格签名和新增 `diagnostic_log=bounded-redacted-export-verified-offline`
  自检通过，播放器身份为 v0.2.47 / build 58，与引擎 v1.2.23 分开；冻结进程的认证 API smoke 通过。
  最终源码指纹与公开包将在下方正式交付核验中记录。
- WebKit 测试在页面脚本启动前注入 clipboard / execCommand spy，不访问真实剪贴板。
- 浏览器已接受的用户点击 `writeText` 无取消 API；关闭后停止后续读取／回退复制，不宣称能撤回已提交的复制。
- 不使用真实浏览器账号或钥匙串；自动化通过不能替代用户现场下载结果。
- 最终源码实际冻结包与认证 API smoke 均通过；冻结身份为 v0.2.47 / build 58，
  engine build `cc03d7a96d7b`，helper 源码指纹
  `5809d10327df9dae28edce5c22eef5df8d64a8b09ce18d136e91e02cb07a943a`。
  初次实现提交时正式 CI 与公开交付尚未完成；以下为后续实测交付记录。

## 正式交付：已核实

- `v0.2.47` / build `58` 于北京时间 **2026-09-29 07:25:21** 正式发布。
  标签固定指向 `5198f11f87309a02883cc17b30c2ae53a97618c7`，未移动标签、覆盖附件或更换更新身份。
- 主线 CI [`36494050477`](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36494050477)、
  标签 CI [`36494057114`](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36494057114)
  首次执行均通过，拼写检查 `36494050494` 通过。期间本机状态查询数次遇到 `Bad Gateway`，
  不属于 CI 失败，未重跑流水线或放宽检查。
- [公开 Release](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.47)
  共八个资产：六个基础文件、从 build 57 的一个增量补丁及其校验和。
  CI 在草稿阶段核对全部资产；本机匿名验证 latest、实际客户端 feed、完整 DMG、唯一增量及其校验和，
  源码包和来源清单在本机只核对资产清单，未声称再次匿名下载其全部字节。
- 使用 v0.2.46 的原公钥认证新 feed、DMG 和补丁，再只读挂载新旧完整包。
  公开补丁实际应用后与公开完整 App 的全部文件、权限、符号链接完全一致；代码签名检查通过。
- 公开增量还原 App 的冻结 helper 自检通过：新增诊断隐私检查、v0.2.47/build58 身份、
  `cc03d7a96d7b` engine build 和上述 helper 指纹均一致。
  实际冻结进程的认证只读诊断 API smoke 通过（3.3 秒），未访问真实 Chrome 或剪贴板。
  同一公开包的四次 Dolby Vision 精确剪辑复测也通过，完整 RPU、帧区间、音频与原片保护均验证。
- 完整公开 DMG：`168770930` 字节，SHA-256
  `76a3c600e704f729f372bff07d68992d664c5d4dd6643a51868bd009e24e1982`。
- build 57 增量：`1041022` 字节，约 **1.04 MB**，SHA-256
  `e0b52a7510da650fc7f8584b318f47a33ed00fae4786ef9b8a1b135e16d3a60c`。
- 公开 feed SHA-256：`4e8d95db0a6b61e81e6055ed4a53564b10042fa8353422eef4469338e4d7b52a`。
- 本机验证脚本退出 0，交付检查与清理分开记录：旧测试卷已卸载，新只读测试卷首次及随后正常卸载返回 16，
  暂保留挂载，没有强制卸载或停用安全服务。上轮 v0.2.46 留下的测试卷本轮已正常卸载。
  没有覆盖用户已安装 App、修改真实配置／下载历史／媒体／模型或收取账号数据。

## 用户复测与限制

更新并重新打开 App，从原链接新建一次下载任务。若失败，打开「诊断日志」，刷新并复制，在退出 App 前发送。
当前面板导出最近创建的最多十个匿名任务；旧记录的原始版本未知，运行过程不会跨 App 重启恢复。
这项能力用于定位实机故障，不等于已确认所有 M4 Max 账号的 Cookie 问题消失。
后续处理仅依据新的安全报告；不要要求用户发送 Cookie、私人浏览器目录、原始日志或钥匙串信息。
