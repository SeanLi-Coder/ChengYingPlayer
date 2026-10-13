# MPV 事件路由与整表交接桥接验证

`run.py` 机械抽取实际 `MPVController` 的命令、属性与事件处理以及 `PlayerCore`
的媒体代次门禁、`idleActiveChanged`，编译实际 `MPVNode`、队列模型和安装器。周围 App/UI 服务是显式
边界，不能把本测试当作完整窗口、像素、位置恢复或可听音频的验收。

```sh
python3 -B Tools/PlaybackBackendRoutingTests/run.py
python3 -B Tools/PlaybackBackendRoutingTests/run.py --sanitize address
python3 -B Tools/PlaybackBackendRoutingTests/run.py --sanitize thread
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control epoch
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control first-start
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-owner
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-start-context
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-completion
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-current
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-route
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-event-gate
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-keep-list
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-list-owner
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-reader-drain
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-stop-preparation
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control pending-volume
```

真实 libmpv 使用 `vo=null` / `ao=null`，不读用户视频、浏览器或设置。生成三秒视频，
以重复 URL 的两项列表选择第二项，验证真实命令返回、不同 entry ID、暂停／非 idle
读回、START → FILE_LOADED 和完整安装收据。真实 `on_load` hook 必须继续，安装时
普通 UI／插件事件不得执行。另以受控 C 事件验证旧 owner 异步投递丢弃、新 owner
不继承前一 START，以及读取时复制 payload 而不是在主线程使用已复用的 C 内存。
全部事件注入使用各 controller 的真实 reader queue，测试 fence 不进入生产代码。

取消专项使用真实部分列表，以及已提交激活但尚未 START 的 `on_before_start_file`、
收到 END 后尚未退场的 `on_after_end_file`。测试显式挂起并释放真实 hook，检查
`stop keep-playlist` 保留 current，阻止提前确认 idle；退出 hook 后才允许核实
idle／无 path／无 current 或 playing、精确 entry IDs，再清表并验证为空。
成功后由抽取的真实 `idleActiveChanged` 取出 pending URL，经明确的开片服务边界
提交真实 loadfile，必须收到真实 START／FILE_LOADED 并读回替换后的单项列表。
另检查重复停止、旧 route／新 owner、外来追加项以及有界超时；失败不得清掉外来项
或假报 idle。特殊停止期间隔离普通属性／生命周期事件，仍释放 hook 和处理 shutdown。
worker 停稳后仍在 stop owner 下异步排空真实 reader，再核验 owner／route／空表，
重设 first-START 门禁并交付 idle。测试单独挂住 reader、让真实 worker 继续退场，
确认 pending open 必须等 reader 释放；生产代码不在 main 同步等待 reader。
Core 在重新开启普通 MPV route 之前调用 `prepareCancelledNativeQueueStop(owner:)`
提前设置门禁，实际 stop 命令仍等后台任务结束后提交。受控旧 idle C 事件经真实
reader 派发的专项检查该窗口；不把受控注入描述为自然事件发生率或端到端 App 验证。
默认 MPV stop 不变，首次 START 门禁没有无条件移除。`vo=null` 不验证实际像素。

每次运行保留 `build/native-mpv-event-bridge.*`，在读取／抽取前冻结全部编译源码、
client header 和候选 dylib SHA；生成代码和素材在编译前、执行后分别校验。
保留编译与运行输出／退出码，失败不得被当作预期负控；负控必须编译成功且仅在
指定断言失败。等待主队列的检查计入总数，普通与 sanitizer 的总数可能不同。

## 2026-10-13 本机证据

冻结 controller SHA `e21853a325788a090c12248c58a1d3c9493bfdb4981070b26b883289cdc4add8`，
runner SHA `5a61367732c23e780359f4ed66feeec5a102a2cee253b67bf6ba879c054c1eb0`：

- 普通 `ttx73dvn`：115/0；ASan `mkqllvwj`：116/0；TSan `3zxzsp0_`：117/0。
- 四负控各在预期断言退出 1，验证器退出 0；epoch `6lqtbnfh`，first-start `2vz8x1r0`，
  queue-owner `pgh19z8q`，queue-start-context `wygoanvu`。
- 所有运行的 source/generated 前后 SHA 一致，没有 sanitizer 诊断。
- 加强 reader 队列隔离时的首轮 `cqrczfcf` 等七次因漏改三个旧 `worker` 引用编译失败，
  没有运行测试；源码／生成物证据保留，详细编译报错在任务输出中。不是负控成功。
  修齐测试引用后才产生以上新结果；同时补了编译日志持久化。
- 更早的桥接测试用 0.05 秒音频充当队列视频，实际在回调前已 EOF，正确返回
  `loadedMismatch`；新队列 fixture 使用视频和正式的 `keep-open` 策略，没有放松收据条件。

以上只覆盖生产桥接，不证明尚在实施的 `PlayerCore` 整队列导航／交接已经通过。
正式默认内核不变。完整 App 构建／窗口验证在 CI 单独运行，目标 M4 AV1 另行验收。

## 2026-10-13 取消后的停止闭环

原冻结控制器在 `t627sxdh` 实际复现部分 append 后取消无法回到 idle，随后 pending URL
不能打开。`o0zwzggs` 保留另一条反证：挂起真实 before-start hook 时，默认 stop 已使
列表为空、idle=true、path=nil，worker 却尚未退出；这些读回不能独立证明卸载完成。
最终修补由 `stopCancelledNativeQueue(owner:)` 独占提交 keep-playlist、验证和清表。
独立 MPVQueueInstaller 的对应 current／playing 清理门禁和真实 hook 测试另见
`Tools/MPVQueueInstallerTests/README.md`；两者都不代表既有 CI 的 partial-cancel
TSan 191/1 已定位或修复。

加入提前 prepare 门禁前的 reader-drain 候选 controller SHA
`7197f096ee14c1f5245cb9826e082a7547a1a7332b073136b23e6ec9c3b6e48a`，
Core `1e48890fffc5435ddd2837b247bbb293d05657f23787931556832197cc022cc1`，
installer `ed5d25f9bfbbc534bf643d0fa0f91ce6c40f348c2248526b396c774a262cb5a4`，
runner `44e724656c5184b030d8bbb39cfc57e06b4dfb376b0b66d298dc941e63072ade`：

- 普通 `3ec989rq`：198/0；ASan `iklygron`：211/0；TSan `huiiwb0q`：218/0。
  总数包含等待主队列的检查，随调度变化；三个模式运行相同场景及断言。
- 十一项负控分别是 epoch `0v011fvr`、first-start `blj8_w7f`、queue-owner `5s1_vj4b`、
  queue-start-context `jwb531_g`、queue-stop-completion `dkxi6go_`、queue-stop-current `op73wm1u`、
  queue-stop-route `c8z7uw_6`、queue-stop-event-gate `gec3ugow`、queue-stop-keep-list `cd6r61ll`、
  queue-stop-list-owner `ug9ag8se`、queue-stop-reader-drain `ky1z5jy6`。
  每项测试退出 1 且命中唯一指定断言，验证器退出 0；不是 sanitizer 崩溃。
- 所有最终运行均保留 source/generated 前后相同 SHA，无 sanitizer 诊断。
  使用仓库 `deps/lib` 的真实 libmpv，不运行完整 App，不验证像素或可听音频。
- 真实前缀快照为八项全部 current=false／playing=false、idle=true／path=nil；
  真实 before-start hook 挂起快照则 current=true／playing=false，仍 idle=true／path=nil。
- `fz3m7mmo` 因抽取真实 Core idle 方法后边界缺少 pending stop owner 字段而编译失败，
  已补显式边界字段后才产生通过结果。`iay7it3y` 的默认 stop 负控被新重复停止断言
  更早拦下，原验证器预期未更新而正确拒绝；随后仅更新精确目标断言名称，未改测试
  断言或生产实现，并重新运行以上全部验证。失败证据均保留。

随后 `0nz9oma1` 以受控旧 idle 属性复现另一个窗口：已收到真实 START 的 controller
在 Core 开启 stop route 后、真正 stop API 设置门禁前，旧属性先派到 main，随后
穿透晚设置的门禁，提前确认 idle。该运行退出 1，不是通过结果。修补将门禁提前
到 route 开启前，并新增仅撤提前赋值的 `queue-stop-preparation` 负控；`nqyidwql`
精确命中 after-START 停止隔离断言，验证器退出 0。最终同源结果追加于下方。

最终包含提前 prepare 的 controller SHA 为
`c06561e71bca8d3d06acbba68028476238a0bdf0b40ba1d0f45c45a7b8120ec4`，
Core `98ff0c4cf304201eb481f40a14b80ff23d7a654a5d80986358a62272937714f7`，
installer 保持 `ed5d25f9bfbbc534bf643d0fa0f91ce6c40f348c2248526b396c774a262cb5a4`，
runner `0e88ef7e3956a170441c56787e7ddb1aa728c9e04a8099918de22eac7f7fabdb`。

- 普通 `s5iw97qq`：206/0；ASan `cv74bt7s`：217/0；TSan `0zj7zo1j`：225/0。
- 普通模式十二项精确负控：epoch `rlp1foln`、first-start `8sdy9wqk`、queue-owner `y0fy6pel`、
  queue-start-context `9afyfp63`、queue-stop-completion `sryi95y_`、queue-stop-current `5w0r_mz1`、
  queue-stop-route `l5hh57pz`、queue-stop-event-gate `4x5vx7k0`、queue-stop-keep-list `11_jmgqp`、
  queue-stop-list-owner `mv4brjyo`、queue-stop-reader-drain `8ldrzzc1`、queue-stop-preparation `gqyqxz2k`。
  每项均只在指定断言退出 1，验证器退出 0。
- 上述所有最终运行均通过源码／生成物前后 SHA 校验；三正向运行无 sanitizer 诊断。
  这是 bridge 和抽取真实 idle 回调的验证，不代替完整 Core／窗口／像素验收，也不关闭
  历史 CI installer 191/1 的未定位问题。

## 2026-10-13 待恢复音量事件展示

`MPVController` 的 volume 属性回调在主线程 route guard 后读取
`player.pendingPlaybackVolume ?? data`，缓存、UI 同步与 OSD 使用同一值；正常 MPV
路径不增加属性查询。fixture 显式提供 pending volume 服务边界，不在测试中重新实现
Core 的 owner 校验。受控 C 事件验证 nil 时使用原始 payload、主线程交付时采用最新
pending 值、显式零值、以及交付前 pending 退役后重新采用原始 payload。这不是
真实 Core 兼容恢复集成的证明。

冻结 controller `8f2d804aa29e79c88b3add8ecd903944abdb499375a0a6653f858673e5529d6a`，
Core `a30bcd0004517da6e55bd6cef80140d6f875dc7ad8269c3e53c7fa30b10297dc`，
runner `536ab5ed47fab0d4e6b46ab5858c885fcf200082896920b51a2e5c5824eaf879`：

- 普通 `769_679b`：210/0；ASan `lxndtzov`：237/0；TSan `qvc2ve91`：232/0。
- 新单变量 `pending-volume` 负控 `lumu52l0` 仅撤掉 pending fallback，精确在
  `Pending restore volume is resolved at delivery for info UI and OSD` 退出 1；验证器退出 0。
- 四次运行源码／生成物前后 SHA 一致，三正向运行无 sanitizer 诊断。既有停止协议
  及测试断言未改变；此前十二个停止／路由负控的精确证据保留于上一节，本次未重跑。

## 首次真实 idle 事件门禁

安装器新增首次 idle fence：Controller 在事件读取线程、native／取消停止路由过滤之前，
用 Atomic 记录实际 `MPV_EVENT_IDLE`；该事实属于同一个 MPV handle，不借用安装 owner，
shutdown 后不再报告就绪。安装器在原有 10 秒 deadline 内等待，不用 `idle-active` 属性、
空 playlist 或成功的 pause 命令代替这一事件。原有卸载 current/playing 检查未改变。
该顺序依赖锁定的 MPV 0.38 实现，升级必须重新核对，不能视为 deprecated IDLE API 的通用保证。

专项从真实 `mpv_wait_event` 取出首次 IDLE 并暂缓交给生产 `handleEvent`，验证此时真实 playlist
仍为空且没有媒体命令；随后交付同一事件，确认记录先于 native gate，且没有普通 UI/plugin 回调，
再沿原真实 queue 场景验证 selected START、FILE_LOADED、entry ID 和节点 readback。
这是延迟事件读取确认的行为测试，**不是**将 worker 固定在 startup `prepare_playlist` 之前，
也不声称确定性复现历史 CI 调度。CI 原失败及锁定源码解释另见安装器专项 README。

新单变量负控 `--negative-control initial-idle-recording` 仅删除生产事件记录，运行完整的
独立 7 检查范围，必须只在
`Production reader records actual IDLE before the native presentation gate` 失败，child 退出 1。
验证器同时要求唯一 CASE、7/1 summary、总计 7 条 PASS/FAIL 和精确唯一 FAIL；缺项、额外失败、
crash、timeout 或 sanitizer 诊断均拒绝。`--initial-idle-only` 跑同一范围的 7/0 正对照。
默认全正向继续调用同一个 helper，再完成真实 selected load；没有删掉旧范围断言。
已有部分列表取消场景先等待真实 IDLE，再断言实际八项前缀，不能以空取消代替原测试。

上一冻结 controller `7afa7834186b0d60703034d7d1d062fd27b8dba5761c61a06a9ad783a26fc63c`、
Core `c0c69a4a99b0fd92a4bedda2aa86f453ca77a4f73b9073c477697004323a94e1` 下：

- 独立正对照 `efrnihgu` 为 7/0；负控 `5z5oo93w` 为精确 7/1、child 1、验证器 0。
- 默认完整正向：普通 `g3qaqli_` 为 220/0，ASan `4cx5tcnv` 为 235/0，TSan `2aobwane` 为 251/0。
  完整 suite 的计数包含实际异步等待中的主队列 drain 检查，因此随调度略变；没有删断言或延长时限。
- 五次输入 manifest SHA-256 均为 `2fe26eb2f723d83cdd0fa78642769a6d6807fe220a483a8b079bdb6d9d83d521`，
  source/generated 前后校验通过，无 sanitizer 诊断，runner 均退出 0。

上述目录使用 `build/native-mpv-event-bridge.` 前缀。本轮新增门禁的负控范围只有明确的 7 项，
没有宣称本轮重跑此前全部 13 个 bridge 控制。Controller 后段音频设备 KVO 虽纳入整文件输入 hash，
并不在本 suite 的事件桥抽取范围内；它的行为由独立专项验证。

Controller 后段新增每个音频偏好请求最多一次 native 交接尝试后，最终整文件
`bf4deeba61947dd675e65792404e0c3138ed9a9f5d3c0e2a994b8356f9a23996`
（Core 仍为上述 `c0c69a4a…`）重新完成同组验证：普通 `67zve9ln` 217/0、
ASan `zo9i6yt2` 235/0、TSan `p8w6gdm7` 240/0，独立正对照 `9lhl6zhb` 7/0，
精确负控 `s5dspzep` 7/1（child 1，验证器 0）。五次输入 manifest SHA-256 均为
`759d69a3427a6fc306f5d5965fecf4871d1d40d4f203a2f338c5ef4728d73675`；
编译均为 0，source/generated 前后校验通过，无 sanitizer 诊断，runner 均为 0。
保留上一冻结的全部证据，不将本 bridge 复验误记为后段 KVO 行为验证。Installer
输入未改变，未因这一后段修改重复运行安装器专项。

最终 Controller `4af2e24de31130e033782dd371ba3027d052ae956001aa000bfac6e31b21d26d`
仅将后段 warning 文案改为准确的“下次打开媒体应用保留偏好”。根代理重新调用实际
extract_production，确认其两份生成 Swift 与 `67zve9ln` 逐字节相同：Production SHA
`838d59584fc76bdeb8e722bb00cff792b9779e128c2a9ba9b6f5ff1cd48d963e`，Player SHA
`5452b5418df9eaa42da5a5b212613ffb3980007533d78c2ed2aefe5cc3af9dce`。
没有为了日志文案再重复三模式；上表完整文件输入身份仍明确属于 bf4deeba，不能说
4af2e24d 已完成新的同源 CI。其后段行为以最终音频偏好专项为准。
