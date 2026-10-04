# 文件／播放列表高度记忆交接

## 范围与使用

基于 `210b0b81`，目标版本 `v0.2.56` / build `67`。
视频窗口右上角文件／播放列表不再硬性限制为 400 点，初始偏好为 600 点。
底部增加 12 点高的拖动区域与小横条：向下延长，向上缩短，松开后保存高度。
两种列表视图、关闭后重开、新窗口与应用重启共用 `playlistHeight`。
窗口较小时临时约束可见高度，不修改偏好；窗口恢复后仍使用保存的高度。
面板不与底部播放条重叠，不因高度偏好把视频窗口撑大。
设置／插件面板保留原 400 点上限，原有宽度调整不变。
图片查看器原有侧栏已随窗口延长，本轮不改其布局。

## 实现与安全边界

`MainWindowController` 使用低优先级目标高度及顶／底空间约束。
新偏好只在有效拖动松手时写入，点击、取消、缩窗和全屏切换不会写回。
非法、非有限或超范围的偏好使用 600 点安全默认值，不改写原记录。
窗口最低高度增加 12 点到 392，保证保留拖动区后，目录视图仍能显示至少一整行。

专用 `PlayerSidebarResizeHandle` 接收鼠标事件，避免被表格滚动或移动窗口截获；
按下到松开持有自动隐藏交互锁，拖动中列表不会消失。
移除面板、OSC 切换和窗口关闭会取消拖动，释放光标和交互锁，且不保存中间值。
关闭先取消拖动再销毁计时器，防止取消回调在关闭过程中重新创建自动隐藏计时器。
不改实际媒体、播放队列、标签、下载历史、浏览器配置、Bundle ID 或更新身份。

## 本地验收

```sh
bash Tools/PlayerChromeTests/run.sh
bash Tools/PlayerChromeInteractionTests/run.sh
bash Tools/PlayerChromeLifecycleTests/run.sh
bash Tools/PlayerChromeIntegrationTests/run.sh
bash Tools/WindowLifecycleTests/run.sh
python3 -B Tools/SparkleUpdateTests/test_release_policy.py
python3 -B Tools/SparkleUpdateTests/test_release_delivery.py
python3 -B Tools/SparkleUpdateTests/test_delta_assets.py
SPARKLE_TEST_ROOT=/path/to/pinned/Sparkle bash Tools/SparkleUpdateTests/run.sh
SPARKLE_FRAMEWORK_DIR=/path/to/Sparkle.xcframework/macos-arm64_x86_64 bash Tools/AppUpdateTests/run.sh
```

- 控件布局 213 项、交互 40 项通过。
- 生命周期 162 项及 4 项全屏源码接线通过；含拖动中关闭后计时器为空、交互深度归零、
  不保存半途高度及迟到松手不重复释放。Intel macOS 10.15 typecheck 和 ASan 通过。
- 集成布局 616 项及独立子进程重启 3 项通过，无 Auto Layout 冲突。
  使用实际生产方法、NSView hitTest 与原生 NSEvent，不是复制拖动逻辑。
  覆盖 600→690 拖动、两种列表、上下极限、小窗裁剪与恢复、全屏、取消、
  新窗口／重启恢复、非法偏好和设置面板不变。独立 UUID 偏好域，不读写用户设置。
- 原生截图已核对：690 点面板底部横条、文件行和播放队列均无遮挡。
- 窗口生命周期 181 项通过，原有触控板滚动、窗口缩放和取消行为保持不变。
- 更新策略 19 项、交付 20 项、增量资产 14 项、实际 Sparkle 签名 23 项通过。
  原生 updater 143 项通过，加入 Double 类型的 `playlistHeight = 690` 保留回归；
  完整安装／重启 fixture 同样种入该值，待发布 CI 实际置换验证。

## 发布状态

本地功能和上述回归通过；尚待主线／标签完整 CI、签名安装、增量全树还原及匿名公开交付。
未覆盖本机正式安装，未发送或修改个人媒体。正式交付后在本节补录真实结果，不能移动旧标签。
