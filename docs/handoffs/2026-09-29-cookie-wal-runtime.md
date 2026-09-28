# 抖音 Cookie 读取再次失败：一致性快照与坏记录隔离

## 范围与当前状态

- 基线 `2050b287`，上一正式版 v0.2.45 / build 56；工作分支 `codex/douyin-cookie-runtime-fix`。
- v0.2.46 / build 57 已于北京时间 2026-09-29 05:48:25 正式发布；标签提交 `1fda80df`，交付核验见下。
- 用户报告最新版仍显示 `cookie_access_unknown`，旧任务重试和原链接新建均失败。
- 本轮未读取真实 Chrome Profile、Cookie、钥匙串或私人配置；不把合成复现等同于已确认用户实机的唯一根因。

## 已复现的问题

使用锁定 yt-dlp 2026.8.19、真实合成 SQLite、模拟钥匙串并阻断外部访问，两位独立审查者复现：

1. 有效抖音 session 加上无关网站的一条非 16 字节对齐 AES-CBC 密文，会中断整个 Cookie 提取。
   底层 ValueError 未被逐条处理，最终只得到 `cookie_access_unknown`。原始字段的无效 UTF-8 也有同类问题。
2. 原提取器只复制 SQLite 主文件，忽略 WAL。新表或记录仍在 WAL 时会报错；已提交删除的 session 也可能从旧主文件被读回。
3. 单视频 generic YoutubeDL 与主页入口的诊断、会话保护和包装后的取消链处理不一致。
   新增容错若仅跳过坏行，可能在丢失目标认证 Cookie 后按匿名数据继续，必须同时修复。

公开 v0.2.45 冻结 helper 的 SQLite、AES 和原 self-test 实际可用；其 PYZ 中相关字节码与审查源码一致。
上次 logger `only_once` 修复确实在包内，本轮没有把它重复声称为新根因。
独立 rednote_downloader 的实际本地 checkout 未找到；初始导入源码使用相同 yt-dlp 路径，
因此不能仅凭两程序表现不同就推定权限、Profile 或用户数据的具体差异。

## 实现与保护边界

- 新增 native-only `chrome_cookie_runtime.py`，在 helper 接受任务前安装固定、线程安全的 yt-dlp adapters。
- 用 SQLite online backup 获取已提交的一致性快照，包括 WAL 新记录及删除；源连接为 `mode=ro`，
  不执行 checkpoint，不把失败降级成复制旧主文件。快照有五秒上限、取消检查和独立的 `0600` 临时文件。
- SQLite 的标准读取协议可能创建或使用 WAL 协调 sidecar；实测主库和原有 WAL 字节不变，
  不能把只读查询描述为源目录绝对没有任何协调文件变化。
- 只逐条处理明确的 macOS CBC 长度错误及 UTF-8 解码错误，不吞掉任意异常、依赖问题或取消信号。
- 主页、浏览器回退、generic 单视频入口均检查实际使用的同一份 Cookie jar；一次读取，不切换 Profile，
  有读取 warning 时必须仍有覆盖目标站点的有效 `sessionid/sessionid_ss`。仅有 ttwid、过期或错域 Cookie 不够。
- 明确关闭 Cookie、明确启用匿名回退的已有行为保留；旧任务仍绑定原 Profile。
  generic 通过结构化 CookieLoadError / ChromeCookieAccessError 链识别失败，不依赖新增异常文案猜测。
- 恢复被 yt-dlp 包装的取消信号，保留原有 progress hook 和 `.part` 恢复行为。
- 增加数据库结构异常、本地存储错误、读取组件异常三个固定白名单类别；保留已识别的 logger 诊断。
  界面不输出 Cookie 值、数据库路径、原始异常，也不把未知错误武断归因于 Chrome 未退出。
- 原始 69 文件来源哈希、许可证和身份校验不变；只更新已审查补丁的 vendored 哈希。

## 本地验证

```sh
build/player-v29-tests.nD75s9/bin/python -B Tools/DownloaderHelper/verify_vendor.py
PATH="$PWD/deps/executable:$PATH" build/player-v29-tests.nD75s9/bin/python -B -m pytest -q -rs Tools/DownloaderHelper/tests
PATH="$PWD/deps/executable:$PATH" build/player-v29-tests.nD75s9/bin/python -B Tools/DownloaderHelper/run_upstream_tests.py
build/player-v29-tests.nD75s9/bin/python -B -m ruff check Tools/DownloaderHelper --exclude vendor
node Tools/DownloaderProxyUITests/main.mjs
bash Tools/DownloadCenterTests/run.sh
```

- 完整 helper：745 passed、62 subtests passed；隔离上游：1405 passed，均无跳过。
- 原生下载窗口英文与中文各 227 项；代理界面 63 项；诊断前端 98 项通过。
- 原生更新界面 143 项、签名更新 23 项、发布策略 19、交付 20、增量资产 14 项通过。
- 实际 `delta-upgrade` 完成 HTTP 补丁下载、安装及一次重启，保留测试设置、书签、历史和模型；未修改用户安装或真实配置。
- 完整上游首轮发现新增通用 early-cancel 改变了原 `.part` 测试时序；已移除这一无关前置检查并保留原测试。
  首轮另一 fMP4 probe 测试使用系统 FFmpeg 路径失败；发行 FFmpeg/FFprobe 下专项和完整测试通过，未修改该媒体测试或放宽断言。
- 本地打包需使用仅含锁定构建／运行依赖的隔离环境。首次测试 venv 因存在开发依赖被构建器拒绝；
  网络安装又因现有代理超时失败。最终在新隔离目录复用已有锁定依赖，移除副本中的开发工具并通过完整环境白名单验证，
  未修改原测试环境或系统代理。实际冻结 helper 构建与严格签名校验通过；构建时及再次执行 `--self-test` 均返回
  `status=ok`、`chrome_cookie_snapshot=wal-and-malformed-data-verified-offline`。
  检查发生在实际内嵌 Python / yt-dlp / SQLite 中，不是仅调用开发环境的函数。

## 正式发布与公开交付

- [v0.2.46](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.46)，build 57，
  发布时间 `2026-09-28T21:48:25Z`，实现提交 `1fda80df8cad883d3fccabf4382605fc2b9dca1d`。
- 主线 CI `36483510196`、正式标签 CI `36483516976` 均第一次执行全部通过，拼写检查 `36483510340` 通过。
  包括实际更新安装／重启、篡改拒绝和回退、4K/HDR 渲染、旋转、截图、打包后剪辑及原有下载器回归。
  本机查看状态遇到 GitHub 网关错误，重新查询恢复；不是 CI 失败，没有重跑工作流、放宽断言或移动标签。
- 八项发行资产在草稿中齐全并经发布流程核验后上线。匿名 latest、实际客户端 feed 与标签 feed 一致；
  本机匿名下载完整 DMG、唯一广告增量及各自校验文件，完整大小和 SHA-256 与发行元数据一致。
  源码归档及来源清单由 CI 核验；本机未重复匿名下载整个源码归档，不扩大匿名字节核验范围。
- 用上一稳定版 v0.2.45 的公钥认证新 feed、DMG、补丁和旧完整包，之后才只读挂载。
  实际应用公开补丁，核对还原 App 的文件内容、权限和符号链接与公开完整 App 全树一致；严格代码签名通过。
- 公开包实际冻结 helper 的 `--self-test` 返回 `status=ok`，同时验证
  `chrome_cookies=macos-v10-aes-and-fixed-diagnostics-verified-offline` 与
  `chrome_cookie_snapshot=wal-and-malformed-data-verified-offline`。
  公开包四次 Dolby Vision 精确剪辑复测通过，保留完整 RPU、帧区间、音频与测试原片；测试后 App 树不变。
- 本机公开验证进程退出 0。正常卸载旧测试卷成功，新只读测试卷首次正常卸载失败，
  清理问题独立记录为 `volumes_detached=false`，没有强制卸载、停止安全服务或吞掉验证错误。
  上一轮 v0.2.45 残留测试卷已在本轮通过正常卸载清理。
- 未改写用户安装、真实浏览器资料、媒体或偏好。保留增量更新、旧签名身份及显式用户选择。

| 公开载荷 | 字节数 | SHA-256 |
| --- | ---: | --- |
| 完整 DMG | 168729003 | `32252e068fadfe13aa2d7ed0267258522c81b73cf81d8b21f741058bd4cf61c9` |
| 从 build 56 的增量 | 1167474 | `e93d444b4de149b71152d80b0afd95d786470129b4ac8e3056027b7416d986e3` |

公开 feed SHA-256：`158cd063f0eeaa3ed9a2a72d399aa9747f1bdf6eb78f5a6c513b286031f5ec6a`。
从上一稳定版更新约下载 1.17 MB；保留完整包回退，不保证跳过版本仍使用该补丁。

## 仍需区分

- 新测试证明上述缺陷存在且被修复，不代表已经在用户 M4 Max 使用其真实账号下载成功。
- 如果更新后仍失败，只反馈新固定诊断类别、播放器版本与 build ID；不请求 Cookie 文件、钥匙串密码、HAR 或完整私人路径。
- 本轮发布与公开交付已完成；上述实机限制仍保留，不能把合成认证保护测试写成用户账号真实下载成功。
