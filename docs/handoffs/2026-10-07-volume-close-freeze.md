# 音量控件与关闭窗口卡住修补

基线：`b380d660797a32a349ba5153a0f9b2cf8a66250c`（最新正式版 `v0.2.67` / build `78` 之后的主线）。
正式版：`v0.2.69` / build `80`。`v0.2.68` / build `79` 是未发布候选，未覆写其标签。
本轮由 Codex 负责唯一发布，正式状态在文末记录。

## 已确认的问题和改动

1. `fileLoaded` 在无音轨时隐藏音量控件，却没有对应的统一恢复路径；音轨列表刷新也未同步控件。
   `updateVolume` 现在始终恢复控件可见性，无启用音轨时禁用并提示，`aidChanged` 与
   `trackListChanged` 均刷新音量 UI。有声视频不继承上一个文件的隐藏状态。
2. 默认上下键把 `add volume` 直接交给 mpv。当 `mute=yes` 时即便数值变大仍然无声。
   普通三参数 `set/add/multiply volume` 进入与滑块、滚轮、菜单及 Touch Bar 相同的
   显式用户调音量路径，非零音量解除静音。复合命令、自定义非音量键位仍保持原路径，
   文本框的方向键不被抢走。新增 `unmute` 参数默认关闭，不改变内部恢复的静音语义。
   有限数检查、活动状态和 mpv 句柄检查在读写前完成；音量命令先于会读取 mpv 的循环模式
   分支，防止关闭后排队按键先触及已关闭句柄。每次新视频音量为 0 的开片 hook 未改。
3. `ViewLayer.display` 的 `NSRecursiveLock` 允许 Core Animation 在 flush 时递归绘制，
   但原主线程优先锁会把正在递归的持锁线程也挡住，造成主线程和渲染线程互等。
   新增受条件锁保护的持锁线程与递归深度，允许当前持锁线程完成，其他后台线程仍让主线程优先。
   模型层和 shadow 共享同一个显示锁及优先机制，释放时配对减深度。
   未取消渲染互斥、未使用超时跳过生产锁，也未关闭硬件解码或降低清晰度。

## 本地证据与边界

- `bash Tools/SilentVideoOpenTests/run.sh`：356 项通过，含真实 libmpv 无音轨→有音轨、
  静音与显式音量路径、原生窗口／菜单／控件焦点、文本编辑、自定义方向键、ASan 和 Intel 类型检查。
  `SILENT_VIDEO_TEST_SOURCE_REF=b380d660` 以及附加 `SILENT_VIDEO_TEST_CASE=muted` 的两条
  负对照分别在运行时重现控件隐藏、调音量后仍静音。
- `python3 -B Tools/PlayerCloseTests/run.py --priority`：8 项通过；加
  `--layer-ref b380d660` 按预期失败，确认旧生产锁的递归互锁，不是只有静态源码断言。
  新用例还验证普通后台竞争者不抢先、嵌套递归所有权保持及主线程递归配对。
- `bash Tools/RenderLifecycleTests/run.sh`：3,855 项通过，含真实 shadow 共享所有权、
  CGL 生命周期、回调关闭、Intel 类型检查和 ASan。
- `bash Tools/WindowLifecycleTests/run.sh`：188 项通过；
  `bash Tools/PlayerChromeTests/run.sh`：213 项通过；
  `bash Tools/PlayerChromeInteractionTests/run.sh`：40 项通过。
- `bash Tools/PlayerChromeLifecycleTests/run.sh`、`bash Tools/PlayerChromeIntegrationTests/run.sh`、
  `bash Tools/PlaybackLifecycleTests/run.sh` 均通过；后两项分别为 618 项和 76 项。
- `python3 -B Tools/ClipPreviewLiveTests/run.py`：324 项通过、0 用例失败、305 帧实际渲染，
  覆盖编辑、控制条自动隐藏、换片、循环落点和面板关闭后的状态恢复。
- `PLAYBACK_SOAK_SECONDS=180 bash Tools/PlaybackSoakTests/run.sh`：3 分钟实际 4K 渲染通过，
  H.264／HEVC Main10 均核实 VideoToolbox，帧缓冲 3840×2160，6 次载入、3 次换片、
  15 次跳转、9 次变速；177 个内存样本，预热后 RSS 增长约 9.9 MiB。
  这不是数小时播放或所有编码的覆盖证明。
- `uv tool run --from typos==1.50.2 typos .`、三种语言资源的 `plutil -lint`、
  `git diff --check` 均通过。
- 自动更新回归：`test_release_policy.py` 19 项、`test_release_delivery.py` 20 项、
  `test_delta_assets.py` 14 项、`Tools/SparkleUpdateTests/run.sh` 23 项通过，
  后者使用本地 Sparkle SDK 验证签名归档、清单及损坏内容拒绝。
  完整 App 的实际签名安装／重启、损坏增量回退和偏好／模型保留由发布 CI 的
  `AppUpdateIntegrationTests` 独立验收，不与签名归档单元测试混同。

生产完整 `ViewLayer` 的合成 4K/60fps 窗口关／开检查分别要求软件解码和实际
`hwdec-current=videotoolbox`。加强后的测试在每次 `FILE_LOADED` 后重新取基线，
等待两个实际彩色帧缓冲画面、播放重启事件及播放时间前进，再关闭窗口；不强制空绘制。
像素采样明确绑定 Core Animation 交付的非零 framebuffer，采样后恢复 GL 读取状态，
保留原有 `frames > 30`，另要求至少 60 次有效画面。最终完全相同源码的
`CHENGYING_TEST_SOFTWARE_GL=1 python3 -B Tools/PlayerCloseTests/run.py` 与
`CLOSE_TEST_HWDEC=videotoolbox python3 -B Tools/PlayerCloseTests/run.py`
分别完成 30 次载入／关闭、61 和 145 次有效画面，均正常清理。
Generic Float 每轮画面就绪实际需要约 1.719–2.256 秒，高于旧的固定 0.1 秒。
窗口委托及部分播放器服务是隔离边界，因此不是完整 App 的 `PlayerCore.stop` 现场复现；
没有用户卡住时的线程采样，不能断言所有现场卡死均由同一问题引起。
新测试通过 `TestAppWorkspace` 精确注销并清理自己的临时 App，不替换 `/Applications` 安装、
不改用户偏好、不读取个人视频。新增关闭实播检查保留生产完整的 core／legacy 与渲染器
初始化路径，严格失败，不把图形初始化失败、卡住或断言映射为可跳过状态。

## 发布状态

`v0.2.68` 候选对应提交 `5713bc95`，CI `37643167193` 未通过，未生成正式 Release，
也未改动现有用户的更新源：

- 下载中心 1,141 个测试中，首次 Chrome 本地页面初始化等待 `/api/config` 超过 5 秒；
  其余 1,140 项与 65 个子测试通过。相同原始合成 Chrome 文件本机连续 4 轮、共 28 项全过，
  保持 5 秒限制、未跳过；没有访问真实 Chrome 资料。本版下载器无变更，现有证据不能把
  偶发冷启动延迟认定为已确定原因。`v0.2.69` 已原样通过这项检查。
- 新增关闭实播测试完成了全部 30 次关闭，但未达到 `frames > 30` 绘制断言。
  原测试每次收到 `FILE_LOADED` 后只固定等待 0.1 秒，没有确认该媒体真实画面已经交付。
  本机 Generic Float 复现了同一旧断言失败。现改为上述有界真实画面条件，
  不通过删除帧断言、跳过测试或改生产播放策略来放行。每轮载入上限 3 秒、画面就绪上限
  8 秒；总 watchdog 390 秒、CI 步骤 10 分钟，包含编译和必须完成的隔离工作区清理。
  独立锁测试的 1 秒获取界限和 10 秒 watchdog 未变，旧生产代码负对照仍明确失败。

### v0.2.69 正式交付

已于北京时间 **2026-10-08 01:04:45** 正式发布，标签提交
`11c77a87ff9d5687d4f5dbac4ebb0ba276a1ef8f`。
[正式 Release](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.69)；
[标签流水线](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/37649414637)。

- 标签流水线的两个测试／构建 job 首次均成功；音量回归 356 项、真实关闭重开 30 轮
  （61 次有效画面）、真实预览 324 项（232 帧）均通过。下载中心 1,141 项及 65 个子测试、
  保留的上游 1,405 项通过。保留其他套件原有的可选环境跳过，不把这些跳过算作实机验收。
- 完整 App 构建与六种实际更新安装／重启场景通过，包含完整包、增量、损坏和不匹配增量
  回退、双重损坏拒绝置换，并验证设置、书签、历史及模型保留。最终 App 的循环边界、
  转换、Dolby Vision／HDR10+ 精确剪辑和快速旋转也通过。
- 首次发布调度遇 GitHub suite 级 `Internal server error`，发布 job 没有运行机器且无执行步骤；
  首次重试 API 返回 HTTP 500。待平台补出该失败 job 后，仅重试发布 job，第二次流水线成功。
  没有修改或重建已验证资产，也未放行失败测试。拼写流水线 `37649404937` 成功；
  同提交的重复主线构建主动取消，完整检查以标签流水线为准。
- 8 项资产齐全；以前一正式版 `v0.2.67` / build `78` 为基线，旧公钥验签及实际增量还原
  与完整包签名文件树一致性通过。DMG 为 `169021370` 字节，SHA-256 为
  `afdc3f5f73d96264c18804b4a603b01e45a9cff1288a5cb1d0e9178cce4465fc`；
  增量为 `1241754` 字节，SHA-256 为
  `cf3ece0dac029e82cc7dbb4265a7d4226e5222bdcce5834c33a938ac53fc9814`。
- 发布 job `112910909527` 于北京时间 **01:04:51** 完成匿名 latest、实际客户端 feed URL、
  完整 DMG 和全部增量下载的大小及 SHA-256 验证。
- 本机另从该 CI 下载完整 8 项资产，使用独立保存的旧版可信公钥验证 feed、完整包和增量签名，
  并核对全部归档校验和。此检查未展开／安装 App；内存中的目标版本策略不冒充新 App 的实际
  `Info.plist`。真实 App 安装与增量基线还原证据来自上述 CI。
- 本机额外匿名交付未完成：Python 3.13 原始 OpenSSL 信任路径缺少 CA，首先返回证书校验失败；
  仅在检查进程内启用已安装的 macOS 原生证书信任、保持证书及主机名校验后，明确返回
  GitHub 匿名 API `HTTP 403: rate limit exceeded`。没有关闭 TLS 验证、修改系统信任或代理，
  也不把本机的验签／受认证 CI 资产下载写成匿名完整下载。公开匿名交付以成功的发布 job
  `112910909527` 为证据；本机限流不等于该已验证公开版本发布失败。

本轮未替换本机正式 App，未改变用户偏好、模型、媒体、Chrome 资料或下载历史。
