# Native viewport controls

这组测试验证内部 native 路径的缩放、平移、复位接入；正式默认仍是 MPV。
不读取用户视频、不修改用户设置、不创建或安装 `.app`，也不需要键盘注入权限。
运行时会短暂显示测试自己的窗口；请勿与其他需要 key window 的 GUI 测试并行。

```sh
bash Tools/NativeViewportTests/run.sh
NATIVE_VIEWPORT_SANITIZER=thread bash Tools/NativeViewportTests/run.sh
NATIVE_VIEWPORT_SANITIZER=address bash Tools/NativeViewportTests/run.sh
```

Runner 先按 Intel/macOS 10.15 检查类型，再执行当前主机架构测试。日志和输入源码 SHA-256
留在打印的 `build/native-viewport-tests.*` 目录。缺少 WindowServer 退出 77，不能算通过。

## 验证边界

- 机械提取真实 `VideoToolsViewport`、`PlayerCore.applyNativeViewport`、Bridge 三个 viewport
  方法和 `PlayerWindowController.handleVideoToolsShortcutEvent`；不是复制一份控制策略。
- MPV、播放器加载状态及 UI 外围服务是显式记录边界；`NativePlaybackSurface` 和附着的
  `AVSampleBufferDisplayLayer` 是生产实现。验证的是实际 model-layer 几何，不是物理屏幕截图。
- 合成 `NSEvent` 直接交给生产快捷键入口；真实自有 key window、文本编辑排除、连续按键、
  0.2～8 倍边界、OSD、禁止触碰闲置 MPV 均有检查。不是通过系统向别的 App 注入按键。
- 独立公式检查 0/90/180/270 度、SAR、横竖图、窗口 resize、非零 bounds origin、零尺寸
  恢复及 normalized pan；原有 point-based API 的语义不改变。
- `fileLoaded` 的同媒体 guard → viewport 恢复 → seek 顺序另有源码契约检查。
  这不能替代完整 App 的异步兼容切换验收。

相关独立回归保留旧断言并增加对应行为：

```sh
python3 Tools/NativePlayerCoreTests/run.py --sanitize address
python3 Tools/NativePlayerCoreTests/run.py --sanitize thread
FFMPEG_BIN="$PWD/deps/executable/ffmpeg" bash Tools/NativePlayerRouteTests/run.sh
bash Tools/NativePlaybackSurfaceTests/run-video-view.sh
VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
```

其中 Core 测试控制异步 session 边界，验证 handoff 快照；Route 使用真实 session/output/view
验证新媒体的逻辑和显示状态共同复位；VideoView 验证替换输出对象不会复活旧 normalized pan。
Live 测试使用真实 libmpv/OpenGL 像素，验证恢复 helper 的 log2 zoom 与 normalized pan 等价，
但没有在这一组里执行整个 native→MPV 生命周期。完整生产 App 验收另由 NativeAppTests 负责。

## 反向对照

以下命令只改本轮临时编译副本，预期退出 1，并出现对应失败。不能把预期失败计作普通通过。

```sh
NATIVE_VIEWPORT_NEGATIVE_CONTROL=pan-y bash Tools/NativeViewportTests/run.sh
NATIVE_VIEWPORT_NEGATIVE_CONTROL=legacy-route bash Tools/NativeViewportTests/run.sh
```

`pan-y` 仅反转 normalized Y 的符号，必须破坏上移与几何检查；`legacy-route` 仅恢复原来的
native 快捷键兼容分派，必须触发“没有请求 MPV 兼容”和连续缩放/平移断言。
每个命令原样保留其余断言，不修改生产文件。
