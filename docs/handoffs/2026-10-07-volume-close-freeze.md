# 音量控件与关闭窗口卡住修补

基线：`b380d660797a32a349ba5153a0f9b2cf8a66250c`（最新正式版 `v0.2.67` / build `78` 之后的主线）。
目标：`v0.2.68` / build `79`。本轮由 Codex 负责唯一发布，正式状态在文末记录。

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
- `uv tool run --from typos==1.50.2 typos .`、三种语言资源的 `plutil -lint`、
  `git diff --check` 均通过。
- 自动更新回归：`test_release_policy.py` 19 项、`test_release_delivery.py` 20 项、
  `test_delta_assets.py` 14 项、`Tools/SparkleUpdateTests/run.sh` 23 项通过，
  后者使用本地 Sparkle SDK，包含签名安装、损坏增量回退及偏好／模型保留。

生产完整 `ViewLayer` 的合成 4K/60fps 窗口关／开检查分别要求软件解码和实际
`hwdec-current=videotoolbox`。最终分别完成 30 次载入／关闭，软件渲染 266 帧、硬解渲染
224 帧。测试生成并播放素材、确认真实帧交付，而非只初始化解码器。
窗口委托及部分播放器服务是隔离边界，因此不是完整 App 的 `PlayerCore.stop` 现场复现；
没有用户卡住时的线程采样，不能断言所有现场卡死均由同一问题引起。
新测试通过 `TestAppWorkspace` 精确注销并清理自己的临时 App，不替换 `/Applications` 安装、
不改用户偏好、不读取个人视频。新增关闭实播检查保留生产完整的 core／legacy 与渲染器
初始化路径，严格失败，不把图形初始化失败、卡住或断言映射为可跳过状态。

## 发布状态

本地修补与回归已完成，正在完成集成复核、正式构建和发布验收。
尚未把标签、草稿或构建中状态当成已发布；最终须记录完整包、增量包及匿名更新交付的验证结果。
