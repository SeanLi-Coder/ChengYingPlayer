# 下载目录按作者组织交接

## 范围与行为

基于 `911a5f22`，目标版本 `v0.2.55` / build `66`。
用户选择 `~/app/data`，作者为 `ABC`，新下载直接进入 `~/app/data/ABC`。
不额外创建 `ChengYing`、`Kuaishou` 或其他平台父目录。
单作品、作者主页批量、失败重试与恢复使用同一持久化目录策略。

- 新安装原生默认目录为 `~/Downloads`，不再预建品牌子目录。
- 已明确保存的目录原样保留，包括用户特意选中的同名品牌／平台目录。
  旧设置若为 `~/Downloads/ChengYing`，请在界面选其父目录并保存，之后新建任务采用新位置。
  不能猜测旧目录是默认值还是用户选择，也不能擅自移动媒体。
- 旧任务缺少新字段时使用原目录策略；已确定输出目录的原生旧任务即使重新发现作者也不迁移。
- 作者改名不改变同一任务已有的目录；新任务使用新发现的作者名。
- 作者名字仍清理非法路径字符；未知作者使用 `Unknown Author`，不添加平台层。
- 不同平台的同名作者共用同名目录；新任务碰到同名文件会增加 ` [2]` 等后缀，不覆盖原文件。
- 明确拒绝作者目录 symlink 和同名普通文件。macOS 使用原子 exclusive rename；
  文件系统不支持时安全失败，不退回可覆盖写入。

## 实现边界

`DownloadCenterService` 只修改初始下载路径，不改变 Application Support 数据根。
`helper.configure_download_layout` 在服务接收任务前启用新任务策略；
`OutputLayout` 写入每个任务，独立 rednote 引擎仍默认旧策略。
TaskManager 保留任务原目录，并让新策略下载器启用 `preserve_existing_files`。
直传与验证后视频都通过安全发布，generic yt-dlp 先在任务私有目录完成再发布。
不修改视频／图片画质、账号绑定、Cookie、代理、素材身份与校验规则。
三个 vendored 生产文件的补丁范围与哈希在完整性清单中登记，原始上游哈希不变。

## 回归入口

```sh
python -m pytest -q Tools/DownloaderHelper/tests
python -m ruff check Tools/DownloaderHelper --exclude vendor
python Tools/DownloaderHelper/verify_vendor.py
python Tools/DownloaderHelper/run_upstream_tests.py
node Tools/DownloaderProxyUITests/main.mjs
bash Tools/DownloadCenterTests/run.sh
```

目录测试覆盖五个平台、单作品／主页、实际 native policy 启用、旧记录缺省字段、
重启／重新发现／作者改名、非法作者名、symlink 和同名文件拒绝。
碰撞测试实际调用生产下载入口、两处 direct 发布及 generic staging，
使用合成 H.264/FFprobe 验证、8 线程竞争、长 UTF-8 文件名和取消边界；
确认原文件字节、inode 和修改时间不变。关闭新保护的隔离负向对照能重现覆盖失败。
API 回归确认用户所选目录不会被追加或剥除，原生中英文 UI 确认提示与实际路径。

不访问真实站点、不读取真实 Chrome 资料、不下载或上传私人媒体；
这些验证证明本次目录与落盘规则，不替代真实站点登录或最高画质验收。

本地验收：目录 41 项与碰撞 17 项专项通过，完整 helper **949 passed、65 subtests passed**，
隔离上游 **1405 passed**，Ruff 与 vendor 完整性通过。
原生 WebKit 中英文各 **295** 项及 fixture 生命周期 **3** 项通过，代理 UI **63** 项通过。
更新策略 19 项、交付 20 项、增量资产 14 项、工作区 37 项（其中 opt-in 系统集成 1 项未启用）、
公开工作区 9 项、实际 Sparkle 签名 23 项与原生 updater 143 项通过。
完整 App 安装／重启与发行附件交付由发布流水线再验收。

## 交付状态

本节将在完整测试、发行构建和匿名更新交付验证完成后补录。
代码提交、CI 成功或发布草稿均不等于正式交付。
