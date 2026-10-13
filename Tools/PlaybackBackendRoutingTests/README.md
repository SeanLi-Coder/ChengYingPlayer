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
