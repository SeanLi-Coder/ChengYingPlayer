# 自动 seek 测量回归

本测试抽取当前生产 `PlayerCore.seek(relativeSecond:option:)`、新媒体重置方法、
`MPVSeekTiming` 和 `MPVController` 的完整测量方法；只在临时编译单元中放宽访问权限。
不创建 `.app`、不打开窗口、不读取用户媒体或播放器配置，也不修改用户设置。

```sh
python3 -B Tools/SeekTimingTests/run.py
python3 -B Tools/SeekTimingTests/run.py --parent-ref d7cc6fea
python3 -B Tools/SeekTimingTests/run.py --live --deps-dir build/scaler-lut-playback.uZAXpM
```

CI 中 `--deps-dir` 指向此次已验证的播放依赖目录。默认是 `deps`，但本机旧的
`deps/lib` 不代表本轮已打补丁的播放库；runner 输出实际 libmpv SHA-256 和可用的补丁清单。
父版本负对照单独运行，必须在“首个 auto seek 确实使用 exact”断言失败；不能把其它编译错误
或其它断言失败当作修复证据。

## 覆盖范围

- 每个文件首个自动 seek 强制精确定位，不继承上一个文件的 keyframe 测量模式；换片重置两个标志。
- 明确选择 exact、relative 和已有 A/B 绝对定位分支保持不变。
- SEEK/RESTART 的单调时钟在事件读取线程捕获，主线程调度延迟不参与相减。
- 一个有效样本最多提交一次；重入 SEEK、旧 token、换片、未加载、非有限时间和五秒过期均拒绝。
- seek/load/stop 等命令立即失效跨线程 token；旧 RESTART 不可恢复新代 readiness。
  新代真实 RESTART 后又能成功采样，避免测试只证明“所有样本都被拒绝”。
- `--live` 用临时生成的六秒 H.264 素材和真实 libmpv，设置 `config=no`、`vo=null`、`ao=null`。
  验证暂停加载、精确 seek 的两个成功样本、真实旧事件延迟投递后被第二个 seek/换片拒绝、stop 清理。

## 边界与保守行为

事件时间仍是读取 mpv 事件的观察时间，不是内核解码计时器；不能据此声称精确测得硬件解码耗时。
mpv 的 SEEK/RESTART 不带请求 ID，因此无法可靠归属的重叠操作丢弃样本，并保留本文件的
默认 exact 策略，不猜测旧事件属于新命令。本轮没有全局 seek 节流、命令重排或降低画质。

五秒期限只限制测量对象生命周期，不限制正常播放/seek，也不会中断媒体操作。
暂停 seek 的 display-link 启停未改；本测试不验证 OpenGL 呈现、音画同步、真实屏幕或交互流畅度。
这些仍由已有 PlayerClose、ClipPreviewLive、A/B 以及播放 soak 回归承担。
