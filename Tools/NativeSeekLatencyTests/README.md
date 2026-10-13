# 原生精确 seek 调度回归

本专项仅覆盖 opt-in 原生 `NativePlaybackSession`，不改变正式默认的 mpv 路径，也不测试
Movist Pro，更不据此宣称两者内核相同。所有素材均由 FFmpeg 合成，不读取私人媒体。

## 生产改动与测量边界

旧实现每解码最多 8 个样本就固定等待 10 ms，连长 GOP 从关键帧追赶到目标位置、丢弃
目标之前的样本时也会等待。候选只让仍有有效解码进展的 preroll 异步立即续排；真正的
输出背压、时钟锚定、flush、稳态播放仍保持原来的延迟调度。每轮保留最多 8 次解码的边界，
另在 preroll 样本之间加入 4 ms 协作式让出；单次解码调用无法被这个时间片抢占。

4K 验证还发现首视频恰好跨越时间片时，旧 preroll 完成条件可能先暂停，来不及排出已暂存
的首个 PCM。修补仅在暂停、尚未提交首音频、FIFO 首项已经到时且输出当前可接收时，保留
一次有界排出机会。不等待所有 FIFO，不等待仍背压或尚未到时的音频，不改变 autoplay 门禁。

`main.swift` 编译真实生产 decoder、sample gate 和 Session，但使用明确可控的输出边界，
**不创建 AV renderer、App、窗口或系统音频**。它测量 seek 请求到首视频样本进入该边界的
时间，不是实际屏幕首帧、完整 App 开片时间或物理扬声器延迟。进入输出时先记录时间，再
提取完整有效 NV12 平面或 PCM block 并计算 SHA-256；控制输出自身的其他调用仍有测试开销。
`NATIVE_SEEK_INSTRUMENT=0` 直接编译原样 Session，去掉调度观察插桩，作为开销对照；此模式
不执行依赖插桩的取消/量子/受控背压检查，不能代替完整回归。

4K 素材为原生尺寸的移动 `testsrc2`，12 秒、30 fps、GOP 300、B 帧、PCM；不是放大的静态
色块。实际解码帧清单必须有 360 帧、至少 100 个 B 帧，关键帧仅在 0 和 10 秒。正向比较必须
使用字节相同的素材，并核对各目标首视频像素、首 PCM、精确 PTS/结束时间。实际硬解与
VideoToolbox 标记只报告已交付的目标视频样本，不能据此认证所有丢弃帧，更不认证 AV1。

## 运行

先选择经过 `RenderTestSupport` 验证的依赖树，不替换项目 `deps`。依赖环境变量省略时
使用项目现有 `deps`；若指定另一棵库树，必须在结果中明确区分。

```bash
export FFMPEG_BIN="$PWD/deps/executable/ffmpeg"
export NATIVE_PLAYBACK_DEPS="/absolute/path/to/verified/dependency-root"
python3 -B Tools/NativeSeekLatencyTests/test_evidence.py
python3 -B Tools/NativeSeekLatencyTests/test_gate.py
bash Tools/NativeSeekLatencyTests/run.sh
```

每轮打印独立 `build/native-seek-latency.*` 目录。退出 0 后还应执行完整证据验证：

```bash
python3 -B Tools/NativeSeekLatencyTests/verify.py evidence /path/to/run-directory
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeSeekLatencyTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeSeekLatencyTests/run.sh
```

下例以此次改动前的 `b931000b` 为 Session 基线；decoder、sample gate 和测试代码保持
同一工作区版本。旧提交必须本地存在，浅克隆不能假装已有这个历史版本。

```bash
set -o pipefail
NATIVE_SEEK_MODE=baseline NATIVE_SEEK_REVISION=b931000b \
  NATIVE_SEEK_SIZE=3840x2160 NATIVE_SEEK_ROUNDS=3 \
  bash Tools/NativeSeekLatencyTests/run.sh | tee build/native-seek-baseline.log
baseline_dir="$(sed -n 's/^Artifacts: //p' build/native-seek-baseline.log | tail -1)"
NATIVE_SEEK_FIXTURE="$baseline_dir/long-gop.mkv" NATIVE_SEEK_ROUNDS=3 \
  bash Tools/NativeSeekLatencyTests/run.sh | tee build/native-seek-candidate.log
candidate_dir="$(sed -n 's/^Artifacts: //p' build/native-seek-candidate.log | tail -1)"
python3 -B Tools/NativeSeekLatencyTests/verify.py compare "$baseline_dir" "$candidate_dir"
NATIVE_SEEK_FIXTURE="$baseline_dir/long-gop.mkv" NATIVE_SEEK_ROUNDS=3 \
  NATIVE_SEEK_INSTRUMENT=0 bash Tools/NativeSeekLatencyTests/run.sh
```

不要并行跑这些性能对照或在测试期间修改源文件/依赖。性能不使用易漂移的倍数门禁；
回归通过的核心是实际解码/输出一致，以及主动追赶不再被人为固定等待限制。

## 负对照与证据

`NATIVE_SEEK_NEGATIVE` 只修改临时复制的 Session，不改生产文件：

| 值 | 必须且只能出现的失败 |
| --- | --- |
| `polling` | 5 次长 GOP 追赶仍有固定等待 |
| `busy-wait` | 真正 video 背压等待不再有界 |
| `quantum` | 控制慢解码时每轮不再按协作时间片让出 |
| `fifo` | 首 video 跨时间片后遗漏已就绪的首 PCM |

负对照使用默认 5 轮，期望子进程退出 1；随后必须用对应验证器核对，不能只看非零退出：

```bash
NATIVE_SEEK_NEGATIVE=fifo bash Tools/NativeSeekLatencyTests/run.sh
python3 -B Tools/NativeSeekLatencyTests/verify.py negative /path/to/run-directory fifo
```

`evidence-status.json` 将 child、tee、源身份、产物身份、依赖身份、结果封存和 runner
状态分别记录。独立验证器重新读取实际 SHA，检查源码前后相同、动态库闭包、生成的 Session、
二进制、素材以及封存后的 `report.json`/`results.log`。报告 schema v2 必须包含声明轮数的
三目标完整矩阵、每条恰好首 video/首 PCM、在播正向 8.7 秒及回退 1.2 秒，以及一致的
PASS/FAIL/RESULT 计数。报告空记录、结果改动、进程崩溃或完整性失败都不能冒充通过/预期负控。

## 验证记录与限制

生产 Session 的原回归已在本次冻结生产代码上通过：`NativePlaybackSessionTests` 209/0
使用独立候选库；未修改的 `NativePrerollAudioTests` 117/0 使用原仓库 `deps`，包含 paused
renderer 像素回读和已提交 PCM，不代表物理屏幕/扬声器。两者不能混称使用相同动态库。

schema v2 的最终结果（目录均在 `build/`，各自 source/产物/依赖/结果身份门禁通过）：

| 组别 | 结果 | 证据目录 |
| --- | --- | --- |
| 4K 旧 Session，3 轮 | 255/0，child/runner 0 | `native-seek-latency.dyZh9K` |
| 4K 候选，3 轮 | 255/0，child/runner 0 | `native-seek-latency.cMV3FI` |
| 4K 原样无插桩候选，3 轮 | 153/0，child/runner 0；仅其声明子集 | `native-seek-latency.WRPfmt` |
| 小素材普通 | 343/0，child/runner 0；`evidence` 0 | `native-seek-latency.N3fLXW` |
| 小素材 ASan | 343/0，child/runner 0；`evidence` 0 | `native-seek-latency.hyO1DM` |
| 小素材 TSan | 343/0，child/runner 0；`evidence` 0 | `native-seek-latency.M6xYbG` |
| `polling` 负控 | 338/5，child/runner 1；`negative` 0 | `native-seek-latency.tOkW74` |
| `busy-wait` 负控 | 342/1，child/runner 1；`negative` 0 | `native-seek-latency.HVW9eW` |
| `quantum` 负控 | 342/1，child/runner 1；`negative` 0 | `native-seek-latency.0PeQ9w` |
| `fifo` 负控 | 340/1，child/runner 1；`negative` 0 | `native-seek-latency.Wm0LIK` |
| 证据/schema 单测 | 39 项通过 | `test_evidence.py` |
| 精确生产 preroll 门禁 | 9/0；另含提取歧义负例 | `test_gate.py` |

旧→候选、候选→无插桩两次 `compare` 均退出 0。同一 4K 动态素材 SHA-256 为
`9bd67a3e20ee296810d46ca2363f10364bd734e64b322a7bc3138eabb19214f2`。8.7 秒目标的
暂停首视频交付中位数为 **2987.856 → 2036.906 ms**，无插桩为 1996.788 ms；在播 seek
单次为 3082.642 → 2056.776 ms。已交付目标视频的实际 H264/VideoToolbox 硬解标记为真。
这些是本机合成素材的控制输出边界结果，不外推到别的机器、所有编码或实际屏幕延迟。

四组负控的失败均限于上表声明的反例，tee/source/generated/dependencies/results 状态均为
0；不能把其预期 child 1 当作完整性校验失败。旧 schema 的通过/预期失败目录继续保留，
未补写新的证据文件来冒充新版验证。

另一个保留的合成 MP4/AAC 诊断素材，在旧 Session 中已经出现部分早期 seek 的 PCM SHA
与从头解码不同，但目标 PTS 和像素相同。使用同一素材的最终诊断如下：

| 组别 | 结果 | 证据目录 |
| --- | --- | --- |
| AAC 旧 Session | 333/10，child/runner 1 | `native-seek-latency.eggJHk` |
| AAC 候选 | 333/10，child/runner 1 | `native-seek-latency.5xkakf` |

两份均通过 `evidence.validate(expected_child=1)` 的身份/完整性检查及 `load_report` 的完整
schema 检查，但严格 `verify.py compare-aac` **退出 1，未通过**：旧 Session 在 1.2 秒目标
的五轮 seek 中有五个不同的 PCM SHA，触发 `Baseline sample contents vary between repeated
seeks`。未放宽此断言，也未更改报告。

另做只读配对诊断：按 `(round, target)` 对照的 15 条 paused 首 video/首 PCM，以及按 target
对照的 2 条 playing 记录，旧/新 Session 的 PTS、字节数、像素/PCM SHA 均逐项相同；10 条
失败列表也完全相同，且仅为 `PCM bytes match origin decode without precision loss`。这只
表明本次调度改动在这些对应轮次未改变既有差异，**不是 AAC 精度通过，也没有解决跨轮
PCM 不稳定的原因**。素材实际为 MP4/AAC；runner 复制后沿用 `.mkv` 文件名，并未转换容器。
