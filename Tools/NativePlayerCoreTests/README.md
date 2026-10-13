# 受控 native 生命周期夹具

`python3 -B Tools/NativePlayerCoreTests/run.py` 抽取实际 Core 生命周期方法；
Session 的异步结束由测试显式 `finish()` 驱动，不运行真实 decoder 或窗口。
`--build-only` 只编译；`--negative-control` 和 `--capture-negative-control`
继续执行原断言与退出码契约，没有删除实际 Core 分支。

## 明确关闭续播保存的旧夹具边界

本目录、NativePlayerRouteTests、NativeClipPreviewTests、NativeRotationHandoffTests、
URLPlaylistEnqueueTests，以及 Surface 的 VideoView／PlaybackLifecycle 子范围
共用 `NoResumeTypes.swift`／`NoResumeMethods.txt`。它们只适配旧 suite 的明确
resume-off 范围，不是续播功能或文件保存的行为证明：

- `.resumeLastPosition` 独立返回 false，不复用 `.pauseWhenOpen`。
- failable Receipt 初始化先核验保存关闭，再返回 nil；全部非 nil 收据成员 fail-fast。
- request/finish 核验 nil；不生成保存结果、排队成功或最终 worker 快照。
- saved-by-native 的 writer drain 在这些范围不可达，调用直接 fail-fast。
- 两套 controlled Session 仍在原 `finish()` 点先交付 `.unavailable` 再完成，
  不制造真实 capture；Route 和 ClipPreview 则继续编译、运行真实 Session。
- 所有 runner 的输入 manifest 纳入两个共享文件。Route 的无记录 lookup 只在
  本套生成片内定义，不改变 CoreQueue 共享 Boundary 或真实保存服务。

真实 Store／Receipt／Service、最终 Session 采点、Core 保存与 MPV 互操作由
独立续播专项负责；这些旧 suite 不宣称覆盖该范围。

新增接口前的四套编译失败完整保留在
`build/resume-legacy-compile.6I1BLu/*-before.log`。修补后四套 build-only 均通过；
Rotation 的 build-only 也编译原四个负控，没有执行其断言。Core 普通 41/0，
两个原负控均按原契约通过；无 GUI 行为未冒充真实 Session 覆盖。

同 Core `d037183d…` 后续验证：Core TSan 41/0；Route `0P1Pal` 335/0；
ClipPreview `FjJLHX` 235/0；Rotation `7FU1aW` 176/0 与原四控 4/10/2/48；
URL 派生夹具 `gILUJJ` 118/0 与原九控 27/9/7/2/3/4/2/2/1。
Rotation 四组、URL 原八组完整失败行分别与保留 CI／旧基线逐字一致，含顺序和重复。
各组 runner/source 校验均为 0；URL build-only `6lpPf3` 也编译全部十个变体。

`OSpm8P` 是未取得独占 GUI 时误启动 Rotation 的原始失败：首个 key-window
断言退出 1，尚未进入业务验证；完整日志保留，不作为负控或被后续 leased 通过抹去。
