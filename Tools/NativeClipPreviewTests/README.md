# 原生区间预览回归

本套明确关闭 resume，使用 `Tools/NativePlayerCoreTests/README.md` 所述严格
nil/fail-fast 保存边界，不访问用户 watch-later 或偏好。原真实 Session 与预览
断言保持；本套不宣称验证新续播保存行为。

这些测试不切换正式默认内核，不改用户设置、媒体或安装的 App，也不生成测试 `.app`。
仅在独立 ignored `build/native-clip-preview-tests.*` 中合成短视频并运行 CLI。

## 运行

```sh
bash Tools/NativeClipPreviewTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeClipPreviewTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeClipPreviewTests/run.sh
```

默认使用 `/opt/homebrew/bin/ffmpeg`；可通过 `FFMPEG_BIN` 指定项目打包的 FFmpeg。
Clang 与 Swift 同时启用所选 sanitizer，不删除或弱化原断言。
`NATIVE_PREVIEW_BUILD_ONLY=1` 只抽取和编译，不生成媒体或运行播放；也可结合负控
selector 检查其抽取与编译，但不能记作行为通过或负控成功。

以下反向控制应以非零状态退出，不能计入通过数量：

```sh
NATIVE_PREVIEW_NEGATIVE_CONTROL=stale-input bash Tools/NativeClipPreviewTests/run.sh
NATIVE_PREVIEW_NEGATIVE_CONTROL=uncancelled-position bash Tools/NativeClipPreviewTests/run.sh
NATIVE_PREVIEW_NEGATIVE_CONTROL=lost-eof bash Tools/NativeClipPreviewTests/run.sh
NATIVE_PREVIEW_NEGATIVE_CONTROL=stale-compatibility bash Tools/NativeClipPreviewTests/run.sh
```

它们分别撤销旧请求通知、位置采点取消、片尾恢复标记，以及兼容交接的用户意图校验。
未知模式退出 `2`，避免拼错后误跑正向测试。

## 真实部分与边界

- 从当前 `PlayerCore.swift` 机械提取预览状态与操作、`pause`、`resume`、绝对 seek、兼容入口和原生退场。
  编译真实 NativePlaybackTransport、Session、Decoder、Output 和 sample gate，不重写它们的算法。
- 面板的 debounce、预览、停止、自动锚点、采点和用户导航方法也从生产代码提取。
  时间字段采用 AppKit 控件，但布局、提示更新、任务状态及时间字符串解析是明确的外部边界；
  这不是完整面板布局或输入法验收。完整旧工具与真实 MPV 预览回归仍需保留。
- 媒体装入及替换是受控边界，真实 Session 执行解码、seek、区间与时钟查询。
  状态枚举使用真实 `PlayerState`；稳定 Session 快照投影为 playing／paused，避免把已就绪的测试媒体
  永久停留在初始 loaded 阶段。首开 pending 与暂停 getter 从生产代码机械提取；准入本身仍是边界。
  兼容测试在真实 native shutdown 完成后记录待装载的 position/pause/A/B，
  **MPV 的装载、ready 和画面是边界，不代表真实主窗口跨内核交接通过**。
  open 的生产仲裁与 generic phase 转换前缀按原样抽取；完成入口显式提供受控
  START/restart 收据，再调用真实 ownership／completion-consumption helper。
  此受控收据不冒充实际 MPV 事件；新 open/close 使用真实 generic invalidation helper。
- 核实连续输入只保留最后请求、无效输入保留基线、同 URL 新 generation、采点取消与重入关闭、
  A=0/仅 A/未设置 A/B、恢复位置与暂停、预览期间音量/倍速及文件循环变更、真实 EOF 后一次播放重启。
- 通过真实 Session worker 队列屏障，让旧兼容采点与同代次的新预览／暂停交错，核实旧交接不会夺走新操作。
- 初始兼容阶段还覆盖真实查询的 ready／failed 两种状态，以及无操作、显式暂停、先暂停再继续。
  Core 的 readiness 是受控边界；核实未 ready 时不会搁置回退、不会丢失暂停意图，
  变成 ready 后新操作仍可取消旧交接。没有将缺失合成文件的失败说成真实 HDR 不兼容验收。
  这些初始用例仅验兼容交接，不包含正常 native 开片的 `receiveNativeSnapshot`／
  `notifyWindowVideoSizeChanged`。后者仍有独立的首开暂停／继续意图接入工作，
  本组通过不能表述为所有开片操作已通过完整 App 验收。
- 不创建 NSWindow，不通过入队计数断言显示成功，不声称像素、扬声器有声、完整 App 或目标 M4 硬解验收。

每轮保留源码前后 SHA-256、生成的测试源码与合成素材摘要、`results.log`、
`source-comparison.log` 和 `generated-validation.log`。源码变化、摘要校验失败、日志写入失败、
sanitizer 或断言失败均阻止成功；失败证据不覆盖。
