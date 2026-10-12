# Native playback session tests

本组使用合成媒体和实际 decoder、session、sample-buffer output。默认与 TSan 模式均保留原来的 209 项检查、A/B 的 1.5 秒观测区间，以及进程 120 秒看门狗。不读取用户媒体，不安装 App。

```sh
FFMPEG_BIN="$PWD/deps/executable/ffmpeg" bash Tools/NativePlaybackSessionTests/run.sh
FFMPEG_BIN="$PWD/deps/executable/ffmpeg" NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativePlaybackSessionTests/run.sh
```

## A/B 失败诊断

原断言先按原截止时间判定。仅当“两次回绕”断言失败后，才输出最多 512 条现有 sampleObserver/onSnapshot 数值事件，包括单调时间、代次、revision、PTS、阶段和队列字节数；若环形记录被覆盖，会明确报告 dropped 数量。记录不持有媒体缓冲区，不在正常逐帧路径打印日志。

随后最多用 1 秒取得一次输出层只读快照。仅沿用旧测试的 immutable worker queue 查找，在该 worker 上读取公开的 clock、rate、flush generation、readiness、已接受样本数及错误是否存在；不跨线程读取 Session 的可变私有字段。若无法取得，报告 unavailable。这个观察发生在原失败之后，不增加通过机会，也不把 enqueue/readiness 当作实际显示或有声证明。

每轮打印独立 `build/native-playback-session-tests.*` 路径，保存 results.log、运行模式、生产与测试源码 SHA-256、全部输入素材 SHA-256，并在进程结束后复核。失败退出码保持非零。一次后续通过不能撤销之前记录的偶发失败。

## 诊断路径负对照

```sh
FFMPEG_BIN="$PWD/deps/executable/ffmpeg" NATIVE_PLAYBACK_DIAGNOSTIC_NEGATIVE=1 bash Tools/NativePlaybackSessionTests/run.sh
```

只将临时测试副本中的一次 deadline 结果强制为 false；不修改生产源码、1.5 秒时限、素材、原有检查集合或其他控制流。预期会输出 FAILURE_TIMELINE 和 FAILURE_OUTPUT_AFTER_DEADLINE，最终为 208 passed / 1 failed、退出 1。真实额外失败仍原样报告，不能把强制失败或稍后恢复误记为普通通过。
