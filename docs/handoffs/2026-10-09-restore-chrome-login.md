# 恢复原 Chrome 下载登录

基线：`97b7137b6047780e251d875c1f00e31bf13a1078`，上一正式版 `v0.2.75` / build `86`。
分支：`codex/restore-chrome-login`。本轮唯一发布者：Codex。
目标候选：`v0.2.76` / build `87`；尚未发布。

## 用户要求

撤掉「打开专用窗口」功能，恢复原 Chrome Cookie 开关和 Profile 选择。
更新后需要的 macOS 文件访问授权由用户手动配置，不尝试自动点授权或修改 TCC。

## 实现与验收边界

- 专用面板和开窗／保存／切换接口一起退役，新任务及总结沿用原 Chrome 配置与预检。
- 旧 dedicated／缺省策略不再阻挡新任务，显式 anonymous 和 Cookie 关闭选择必须保留。
- 匿名迁移先持久化 Cookie 关闭，再退役策略；总结读取需避免并发迁移读到旧 Cookie=true。
- 已有专用任务只读原快照，不换平台／修订、不退回 Chrome 或匿名；失效时提示从原链接新建任务。
- 不删除浏览器资料、任务、媒体或设置，不读取真实 Cookie／钥匙串进行回归，不改其他平台适配。
- 公开包自检同步验证新登录策略及旧身份兼容，不能只改界面或仅替换成功字符串。

## 当前验证

自动更新策略、发行交付、增量资产与公开验证工具：64 项、110 个 subtests 通过。
公开验证工具新增用例拒绝旧专用入口自检标记；不启动真实 App、不读取用户资料。
本机完成以下回归：

- `CHENGYING_REQUIRE_CHROME_UI=1 .../python -B -m pytest -q -rs Tools/DownloaderHelper/tests`：
  1,373 项及 65 个 subtests 通过，无跳过；日志 `build/restore-chrome-helper-full.log`。
- `.../python -B Tools/DownloaderHelper/run_upstream_tests.py`：隔离上游 1,405 项通过，
  禁止非回环网络；日志 `build/restore-chrome-upstream.log`。
- 原生 `bash Tools/DownloadCenterTests/run.sh`：中英文各 304 项及 Intel typecheck 通过，
  工作区精确注销、子进程收尾和清理成功；日志 `build/restore-chrome-native-ui.log`。
- 实际隔离 Chrome 回环页面、Profile 与诊断文案 122 项通过；Node Profile 51 项、Proxy 63 项通过。
- source helper 的协议、认证、旧 API／资源撤除、代理、重启和 EOF smoke 通过，
  不执行认证后的真实 Profile 枚举；日志 `build/restore-chrome-source-helper-smoke.log`。
- 实际 Sparkle 签名／增量构建 33 项及 69 个 subtests 通过；两个 pytest collection 警告
  来自辅助工作区类带构造函数，不是跳过测试。
- 原生 updater 143 项通过；六种签名安装场景（完整、增量、坏完整包、坏增量、不匹配增量、
  双坏包）均通过；成功路径实际置换／重启且保留合成配置、模型、历史和登录资料，
  错误路径拒绝或回退。全部受管工作区正常清理，日志 `build/restore-chrome-update-install.log`。
- Ruff、vendor 完整性及 `git diff --check` 通过。仅更新实际修改的 app.js 集成散列，
  不更改 69 个原始上游散列或来源归属。

迁移回归覆盖先关闭 Cookie 再退役策略、第一／第二步写失败、重启幂等、之后显式重新启用，
以及总结进程的两种确定性交错。旧快照只读测试检查目录不新建、无开窗方法、旧修订不更换。
初次专项测试的错误导入与一个测试中误放断言已修复后重跑通过，未放宽生产检查。
独立最终 review 无未解决阻断。没有读取真实账号、Cookie、钥匙串或用户设置。

正式冻结组件、完整 App 构建与公开交付尚待完成，不能将候选写成已发布。
