# Native retirement snapshot regression

仅验证 `NativePlaybackSession.shutdown(capturingState:completion:)` 的真实 worker 采点与关闭。
直接编译生产 Session、sample-buffer output、sample gate 和 CYN 解码器；使用独立生成的
FFV1/PCM 与 H.264/AAC 合成媒体、实际 AVFoundation 共同时钟，不运行完整 App、不读写用户
媒体、偏好、watch-later 或正式安装。默认播放后端没有改变。

## 接口约定

- `capturingState` 可省略，原有 trailing-closure 调用保持源码兼容。
- 首次 shutdown 在 main 立即标 terminal 并取消解码；worker 在 reset 前采点，必须仍是
  同一个 pre-shutdown revision / generation 的真实稳定 playing / paused / ended，
  已有 decoder / media、正有限 duration、有限非负输出时钟，且不在 preroll。
- 未执行的 open / seek / stop、正在 preroll、opening / failed / idle 不填零，也不将旧
  媒体的快照当作新请求结果。正常 query 的 superseded / terminal unavailable 门禁不放宽。
- capture 与 completion 各自仅一次，均在实际 output 清理完成后回 main，先 capture 后
  completion。重复关闭（包括 capture 回调重入）返回 unavailable，不复用首份快照。
- 已排队但尚未应用的 volume / rate / pause / loop 仍按既有取消规则失效；快照只描述
  worker 实际应用的值，不承诺保存用户最后一次尚未执行的点击。Core 的预览 checkpoint、
  退出 receipt、写入与恢复由其他专项验证，本目录不能替代那些验收。

## 运行

```bash
bash Tools/NativeResumeSessionTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeResumeSessionTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeResumeSessionTests/run.sh
NATIVE_RESUME_SESSION_NEGATIVE=drop-owner bash Tools/NativeResumeSessionTests/run.sh
NATIVE_RESUME_SESSION_NEGATIVE=allow-preroll bash Tools/NativeResumeSessionTests/run.sh
NATIVE_RESUME_SESSION_NEGATIVE=drop-cancellation bash Tools/NativeResumeSessionTests/run.sh
NATIVE_RESUME_SESSION_NEGATIVE=duplicate-callback bash Tools/NativeResumeSessionTests/run.sh
NATIVE_RESUME_SESSION_NEGATIVE=capture-after-reset bash Tools/NativeResumeSessionTests/run.sh
```

可用 `NATIVE_PLAYBACK_DEPS=/absolute/verified/dependency/root` 指定隔离依赖；不替换仓库 deps。
`BUILD_ONLY=1` 只编译，不执行 AppKit / Session 行为。运行时须与其他媒体 GUI 测试串行，
子进程整体 90 秒 watchdog，退出非零、超时、崩溃、缺失 summary 或少跑任何检查都不能算成功。

148 项完整标签集固定于 `verify.py`；正常必须全部通过，五个负控必须只出现各自规定的
失败集合且 child exit 1。负控仅在自有 build 目录复制并单变量修改 shutdown，不改生产。
所有运行保留编译／执行／最终退出状态、源清单前后 diff、生成物与媒体 hash、SDK／动态
依赖校验。精确负控被接受时 runner 返回 0，与它的 child exit 1 分开记录。

测试屏障仅排序真实 worker 操作，进入和释放分别有界；每个屏障必须明确收到 release，
超时自然放行不能冒充确定性顺序。取消检查是在 worker reset 之前实际调用 decoder，
要求得到对应 domain/code 的 cancelled 错误，不用手填 cancelled 状态。preroll 场景先
执行真实 seek，再阻挡其 pump，并核实实际 seeking 通知；不会伪造 ready snapshot。

## 本地证据（2026-10-13）

生产 Session SHA-256：
`06ecda97d3a1d88b6134c8a8e0e44210add6e70c4be0614452afa5593dc6f387`。
实际运行用隔离 `build/native-av1-playback.7FMHum` 依赖；首轮 `4mm5ZV` 为 139/0，随后仅
追加真实 preroll 到达确认和调用者释放 Session 的生命周期检查，最终为 148 项。

| 模式 | 证据目录（`build/native-resume-session.*`） | 结果 |
| --- | --- | --- |
| 普通 | `axbmVw` | 148/0，child / runner 0 |
| ASan | `g6kmxY` | 148/0，child / runner 0 |
| TSan | `dDJe5C` | 148/0，child / runner 0 |
| `drop-owner` | `vW65on` | 144/4，仅待处理 seek / 两种 open / stop 的旧快照拒绝断言失败 |
| `allow-preroll` | `v3OPcx` | 147/1，仅真实 seek preroll 不可保存断言失败 |
| `drop-cancellation` | `nx100g` | 146/2，仅即刻 decoder cancellation 与未应用命令保护断言失败 |
| `duplicate-callback` | `nV53TL` | 131/17，仅精确回调次数与首份 receipt 断言失败 |
| `capture-after-reset` | `o5ijAV` | 137/11，仅有效最终快照相关断言失败 |

上述八份源码清单同为
`73b0378077d263551f3672a0cad30e58f2cf19f6db03bef72a9b088faffafbeb`，源、生成物、合成素材与
依赖前后校验均通过。五个负控 child 均为 1、精确 verifier 与 runner 均为 0；全部完整执行
148 个唯一标签，无额外失败、崩溃或超时。此前五个 build-only 目录只记为编译证据，不冒充行为通过。
完整 App / Core 保存与恢复、实体画面／可闻声音、目标 M4 验收均不由本组结果证明。
