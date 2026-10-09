# 恢复原 Chrome 下载登录

基线：`97b7137b6047780e251d875c1f00e31bf13a1078`，上一正式版 `v0.2.75` / build `86`。
分支：`codex/restore-chrome-login`。本轮唯一发布者：Codex。
目标候选：`v0.2.77` / build `88`；尚未发布。

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

## 发布前阻断：暂停复位丢掉末次重绘

`v0.2.76` / build `87` 候选提交为 `1cfab830016c90a33b4ab709c3afc5c55ec522db`。
下载回归和拼写检查通过，但主线 `37953632760` 的实际缩放／平移检查失败：
复位后的属性已为零，红色标记纵坐标仍为 161.5，而预期为 179.5；20 秒观察内帧数停在 24。
虽然标签构建同项通过，仍于发布前取消 `37953636485`，`v0.2.76` 未发布，标签不移动。
保留失败日志 `build/release-v0.2.76-main-failed.log`，不把重新跑绿当成解决。

静态检查发现 mpv 0.38 在等待重绘超过 200 ms 后将 `next_frame` 移入 `cur_frame`，
使 update 的 FRAME 位消失；测试驱动与生产图层原来均依赖这个位，可能遗漏暂停下的最后一次画面更新。
受控实验在最终 pan-y 复位回调到达后停止宿主绘制 400 ms，使用已验证的五补丁播放库：
`build/scaler-lut-playback.uZAXpM/lib/libmpv.2.dylib`，
SHA-256 `2bdcbd6e80d3dd383d1676be907920aa7fb41195d990fb0e5d13f7417a280c3b`。
日志同时核对实际加载路径、callback=1／FRAME=0，以及真实 VO 丢帧计数 0→1。

- 旧门控负对照退出 1，复现与 CI 完全相同的 y=161.5／24 帧；
  `build/restore-chrome-viewport-drop-count-negative.log`。
- 保留回调的修补对照退出 0，复位到 y=179.5，全部 148 项通过；
  `build/restore-chrome-viewport-drop-count-positive.log`。随后增加“确实执行故障注入”断言，
  最终硬件解码版本包含受控丢帧验证，149 项通过；`build/restore-chrome-viewport-hardware.log`。
- 最初 `build/restore-chrome-viewport-baseline.log` 使用的是旧 deps 库，虽通过，
  不将其当成当前五补丁发行库的验证依据；后续始终显式选择并记录库身份，未替换 deps。

生产图层同步保留回调，并继续服务 advanced-control dispatch；绘制期间的新回调不能被清掉。
独立机械抽取的图层回归覆盖它自己的生命周期。真实 libmpv 实验不是完整播放器窗口实测，
不把测试驱动的结果冒称生产窗口已复现。像素容差 2 px、观察 20 秒与总 watchdog 90 秒均未放宽。

最终修补回归：

- 五补丁库、强制 Apple Software Renderer：普通与 350 ms 旧帧读回均 149 项通过；
  反转纵向平移和 30 秒陈旧读回均准确退出 1，日志分别为
  `build/restore-chrome-viewport-{software,delayed-readback,inverted-negative,stalled-negative}-final.log`。
- `bash Tools/RenderLifecycleTests/run_updates.sh`：48 项、Intel typecheck 与 ASan 通过；
  单行恢复旧 FRAME 门控的负对照退出 1。完整 `run.sh` 的原生命周期 3,855 项也通过，
  日志 `build/restore-chrome-v77-render-lifecycle.log`。
- `CHENGYING_TEST_SOFTWARE_GL=1 .../python -B Tools/PlayerCloseTests/run.py --deps-dir build/scaler-lut-playback.uZAXpM`：
  真实生产图层、4K 软件解码反复关闭／重开 30 次，90 帧、61 个有效画面，退出 0；
  测试 App 精确注销与临时工作区清理成功；`build/restore-chrome-v77-real-close.log`。
- 版本递增后更新策略／交付／增量资产／公开验证工具 64 项、110 个 subtests 再次通过；
  `build/restore-chrome-v77-update-policy.log`。此前签名安装、下载模块和原生下载 UI
  结果仍针对相同未改的对应实现，冻结发行包另由后续完整 CI 验证。
- 独立代码复审无未解决阻断；未将真实跨屏 shadow 路由称为已测试，也未盲目共享
  model／shadow 的瞬时 pending 状态。没有修改系统权限或正式安装。
