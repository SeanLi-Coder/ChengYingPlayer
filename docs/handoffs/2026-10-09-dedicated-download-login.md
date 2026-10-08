# 独立下载登录与升级后权限体验

基线：`7e509959`（上一正式版 `v0.2.69` / build `80` 后的文档提交）。
候选：`v0.2.70` / build `81`。本轮唯一发布者为 Codex；尚未宣称正式发布。

## 用户需求与实现

用户接受专用登录方案，目的为停止默认依赖日常 Chrome 的受保护资料，
不是授权修改 TCC、自动点系统权限或跳过网站登录。

- 下载中心新增六平台独立登录面板，首次手动登录后显式保存。
- 默认 `dedicated`；旧 Chrome、匿名公开模式均需用户明确选择并保存。
- 登录方式、专用 Chrome profile 和不可变 Cookie 修订位于已有 DownloadCenter
  Application Support 数据目录，App 更新不搬动、不覆盖。旧偏好与任务不迁移。
- 每个新任务绑定该平台当时的修订；旧任务重试不更换身份。登录更新后明确要求新建任务。
- 保存／读取检查平台认证 Cookie 的域、根路径、非空及过期时间，统计 Cookie 不能冒充登录。
  这是本地启发式，不代表网站已认可登录；账号被服务器撤销仍需要实站响应确认。
- Cookie 仅导出允许平台域，分区 Cookie 不扁平化；文件／目录 0600／0700，
  无跟随链接读取、限制大小、拒绝重复 JSON 字段，快照原子写且旧修订不覆盖。
- pinned yt-dlp 所有提取入口、XHS 预检及总结音频／字幕复用专用资料，禁止匿名回退。
  修复 CookieJar 复制导致 host-only 策略丢失，验证真实 requests 请求头和重定向。
- 专用窗口沿用保存的代理，无隐式直连重试；打开／保存／关闭期间阻止代理更换与更新安装。
  关闭未确认不会发成功状态，也不会解除 watchdog；不会终止日常 Chrome。
- API／任务响应不含 Cookie、账号、路径或专用修订标识；保留固定诊断码供反馈。

## 已验证与边界

- 上游隔离回归：1,405 项通过；原始 69 文件的来源哈希未改。
- 原生 WKWebView：中英文各 323 项通过，另 3 个 runner 测试通过。
- 真实隔离 Chrome UI：32 项通过，使用实际下载器 HTML/app.js 和本地 API fixture。
- 下载模块完整回归：1,373 项通过、65 个 subtests 通过，无跳过；包含独立存储、认证接入、API、总结与真实隔离 Chrome UI。
- 独立安全复核通过：总结的两条请求路径均保留 host-only Cookie 策略；关闭失败不解除 watchdog；旧任务不换身份。
- source helper 协议／私有 API／重启 smoke 通过。新增冻结自检验收和实际更新保留
  专用登录配置、快照、浏览器会话合成文件的检查。本机真实签名全量更新／替换／重启检查通过；冻结构建及其他更新场景待 CI 完成。
- `ruff check`、`git diff --check`、vendor 完整性与 `typos==1.50.2` 均通过；发布策略 19 项、公开验收工具 10 项通过。
- 所有测试使用合成资料，没有读取用户日常 Chrome、钥匙串、真实 Cookie 或测试其他账号。
  没有向真实网站登录；六平台入口已接入不等于六平台真实账号验收。
- Google 可能拒绝自动化控制的专用 Chrome 登录，界面明确告知，保留显式旧模式或匿名模式。
- 认证 Cookie 格式可变化，未知格式会停止而非猜测。现有 Qwen Instagram 站点适配清单未接管。
- 关闭异常时只能报告未确认并保持屏障；未证明所有异常下浏览器进程均能自动清理，
  界面提示只手动关闭专用窗口后重开播放器，不要求强制结束日常 Chrome。

### 本机复核命令

```sh
CHENGYING_REQUIRE_CHROME_UI=1 build/player-v29-tests.nD75s9/bin/python -m pytest -q -rs Tools/DownloaderHelper/tests
build/player-v29-tests.nD75s9/bin/python -m ruff check Tools/DownloaderHelper --exclude vendor
build/player-v29-tests.nD75s9/bin/python Tools/DownloaderHelper/verify_vendor.py
build/player-v29-tests.nD75s9/bin/python -B Tools/SparkleUpdateTests/test_public_workspace.py
build/player-v29-tests.nD75s9/bin/python -B Tools/SparkleUpdateTests/test_release_policy.py
SPARKLE_TEST_ROOT=build/sparkle-local-updater.tmslcJ/sdk build/player-v29-tests.nD75s9/bin/python -B Tools/AppUpdateIntegrationTests/run.py --scenario upgrade
```

## 发布记录

尚未发布。必须完成完整回归、冻结 helper、DMG／更新签名、实际更新保留测试和匿名交付核验后更新此节。
