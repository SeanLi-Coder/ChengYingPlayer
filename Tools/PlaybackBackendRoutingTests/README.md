# MPV 事件路由与整表交接桥接验证

`run.py` 机械抽取实际 `MPVController` 的命令、属性与事件处理以及 `PlayerCore`
的媒体代次门禁，编译实际 `MPVNode`、队列模型和安装器。周围 App/UI 服务是显式
边界，不能把本测试当作完整窗口、像素、位置恢复或可听音频的验收。

```sh
python3 -B Tools/PlaybackBackendRoutingTests/run.py
python3 -B Tools/PlaybackBackendRoutingTests/run.py --sanitize address
python3 -B Tools/PlaybackBackendRoutingTests/run.py --sanitize thread
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control epoch
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control first-start
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-owner
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-start-context
```

真实 libmpv 使用 `vo=null` / `ao=null`，不读用户视频、浏览器或设置。生成三秒视频，
以重复 URL 的两项列表选择第二项，验证真实命令返回、不同 entry ID、暂停／非 idle
读回、START → FILE_LOADED 和完整安装收据。真实 `on_load` hook 必须继续，安装时
普通 UI／插件事件不得执行。另以受控 C 事件验证旧 owner 异步投递丢弃、新 owner
不继承前一 START，以及读取时复制 payload 而不是在主线程使用已复用的 C 内存。
全部事件注入使用各 controller 的真实 reader queue，测试 fence 不进入生产代码。

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
