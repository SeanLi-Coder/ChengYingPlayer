# 抖音 Cookie 读取修复与 HDR 默认开启

## 基线与范围

- 基线：`1c885bab`，上一正式版 `v0.2.42` / build `53`。
- 工作分支：`codex/douyin-cookie-hdr-default`。
- 目标版本：`v0.2.43` / build `54`。本节记录实现；正式发布结果见末尾追加记录。
- 用户授权修复播放器抖音 Cookie 失败，并将 HDR 默认改为开启。
  独立 rednote_downloader 不在本轮修改范围。

## 已修复

1. 两个抖音 Cookie 提取入口的 quiet logger 不支持 yt-dlp 的
   `warning(..., only_once=True)`，会将解密异常再次变成 TypeError。
   现在共用兼容 logger，只留固定诊断代码，不留原始 warning 或 Cookie 内容。
2. 有解密 warning 时，仅在仍有覆盖抖音主站、根路径的有效
   `sessionid/sessionid_ss` 时允许继续。无关坏 Cookie 不再必然中断正常会话；
   只有追踪 Cookie、过期 Cookie、其他子域或无关路径的 Cookie 不能作为登录仍可用的证据。
3. 签名入口、主页浏览器回退和通用 yt-dlp 单视频入口均保留安全诊断及取消信号。
   错误不再强行等同于验证码、网站变化或钥匙串拒绝；不增加静默匿名回退。
4. 自动 Profile 的诊断不再假定 `Default`。界面新增现有 Chrome Profile 设置入口，
   提示如何从 `chrome://version` 找到目录名称；保留空值的既有选择逻辑。
   保存不会改变旧任务绑定，创建任务时阻止未保存或仍在保存的 Profile 变更。
   未编辑的旧显式路径值原样保留，不因保存其他设置而损坏。
5. HDR 注册默认值、初始播放状态与设置复选框改为开启；显式保存的 true/false 均保留。
   不修改 v0.2.42 的 HLG/Dolby Vision 基础层与 SDR 色彩状态修复。

## 测试与隐私

- Cookie 专项使用真实锁定 yt-dlp、AES 和合成 SQLite，模拟 keychain；
  不访问真实 Cookie、账号或钥匙串，不以真实用户素材作公开 fixture。
- 冻结 helper 的 `--self-test` 增加同类 AES/提取/诊断检查；不只检查导入和版本。
- 上游隔离 runner 为诊断提供逐测试临时 Chrome 根目录，不替换 HOME，
  不把开发机的浏览器目录用于错误分类；保留已有外网阻断。
- 原有 69 文件来源与许可证不变；新增 `app/douyin.py` 精确补丁白名单，
  更新已审查的 vendor 哈希，不改原始 upstream 哈希。

本机已执行：

- `python Tools/DownloaderHelper/run_upstream_tests.py`：1,405 passed。
- `python -m pytest -q -rs Tools/DownloaderHelper/tests`：583 passed、62 subtests passed；
  随后新增 runner 隔离验证，该文件复跑 7 passed。
- Cookie 提取专项 31 passed；通用诊断专项 26 passed；冻结 Cookie 模块 3 passed。
- `python -m ruff check Tools/DownloaderHelper --exclude vendor`、vendor 校验、diff 检查通过。
- `node Tools/DownloaderProxyUITests/main.mjs`：63 checks。
- `bash Tools/DownloadCenterTests/run.sh`：英文与中文各 227 checks，Intel 类型检查通过。
- HDR 偏好 42 checks、色彩状态 149 checks，Intel 类型检查通过。
- 更新策略 19 tests、增量资源 14 tests、更新交付测试通过；真实 Sparkle 签名 23 tests。
- 原生更新界面 143 checks。

## 仍需区分的现场问题

上述修补覆盖已复现的软件缺陷，不等于已在用户 M4 Max 完成真实账号下载。
用户机器的 keychain 授权、具体 Chrome Profile 和站点访问权限仍需正常授权与验收。
播放器与独立下载器配置目录相互独立；关闭 Cookie 或换 Profile 后应新建任务，
不能以旧任务重试证明新配置是否生效。不要要求用户发送 Cookie、钥匙串密钥或完整配置。
实体 HDR 屏幕的显示效果仍需目标机器验证；保留用户明确关闭 HDR 的选择。

## 发布状态

实现与本机检查已完成，等待正式 CI、安装包和公开更新链验收。
在追加公开交付证据前，不将本记录视为发布成功声明。
