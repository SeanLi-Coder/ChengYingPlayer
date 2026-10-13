# 未打开 native 队列的 MPV 续播交接

本专项抽取真实 `PlayerCore` 队列、准入、`fileLoaded`／`playbackRestarted`、
seek／速度方法，编译真实 Session、transport、安装器，并使用实际 libmpv。
合成媒体与 watch-later 全部位于每次独立 `build/native-queue-resume.*`。
不访问用户偏好或 Application Support，不运行完整 App。

```sh
bash Tools/NativeQueueResumeTests/run.sh
NATIVE_QUEUE_RESUME_BUILD_ONLY=1 bash Tools/NativeQueueResumeTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeQueueResumeTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeQueueResumeTests/run.sh
```

实际 MPV 从合成媒体精确 seek 后写出 `start`／`speed` 记录。测试由公共
`openMediaURLs` 经过真实异步库存检查与完整重复列表安装，读取实际位置、速度、
暂停、音量、列表及记录消费结果。已有 native 播放的对照必须继续使用实时捕获位置
和精确 seek，不能被较旧 watch-later 替换；切换中的速度与 seek 意图分别验证。

应用窗口／偏好／历史服务继承 `NativeCoreQueueTests` 的明确边界。仅测试独立
进程内的合成偏好值，不写 UserDefaults。真实 MPV 使用 `vo=null`／`ao=null`，
不验证 MPV 像素或物理音频。保存路径 MD5 边界匹配当前生产小写规则，并断言
该路径确实指向 MPV 写出的文件；不是大小写敏感文件系统的互操作验收。

Core 夹具的 MPV 事件适配在 main 同步驱动，不是生产异步 reader 的证明。
对应实际 `MPVController` 安装 owner／首 restart 顺序由独立 bridge scope 验证：

```sh
python3 -B Tools/PlaybackBackendRoutingTests/run.py --queue-resume-only
python3 -B Tools/PlaybackBackendRoutingTests/run.py --negative-control queue-resume-restart
```

## 保留的旧源码证据

Core SHA `c0c69a4a99b0fd92a4bedda2aa86f453ca77a4f73b9073c477697004323a94e1`，
`3vF1WW` 编译 0、child 1、runner 1；完整 36 项中恰有 2 项失败。
实际 MPV 写出 `start=2.250000`、`speed=1.500000`；进入 Core `fileLoaded`
前实测为 2.25／1.5，随后生产发出 `seek 0.0 absolute+exact`，最终实际值为
0／1。失败仅为未打开队列的保存位置和速度保留。完整重复列表、音量 0、暂停、
owner 退役及记录消费均通过；已播放 native 的 1.25 秒精确恢复和最后 1.75 倍
速度意图对照通过。source/generated 前后核验成功，原失败不被后续结果覆盖。

锁定 MPV 源码先发 `FILE_LOADED`、后执行初始 watch-later seek。因此不能用
一次 `FILE_LOADED` 时刻的 `time-pos` 查询当通用同步屏障。上述一次实际读回
恰已达到 2.25 秒，不是所有调度都如此的保证。

`pBt5Ar` 是并行生产续播声明落盘期间的 build-only 编译失败：抽取声明已引用
`NativePlaybackResumeReceipt`，当时测试尚未接新类型。没有行为结果，不算负控。
`5f6K8p` 保留初版生成器把 Store 的 `fileprivate` 错误改写后的编译失败；已将
真实 Store／Service 拼接移到 Core 可见性处理之后。`HurURQ`／`N8nH73`
随后 build-only 编译及 source/generated 校验均通过，没有运行行为断言。

共享生成器现在包含实际 Store、Receipt 和 Service。唯一偏好边界将 service 的
`shared` 换成 UUID 独立 suite，并在 volatile argument domain 明确设保存为 false；
存储根为本次 artifact 的 `native-resume-records`。本专项的 MPV 读取续播仍为 true，
native writer 关闭是显式测试范围，而不是生产偏好语义。LastPlayed 与缓存写入只记
进程内数组，不读写用户资料。真正 native 保存验证由独立 Core 续播专项负责。

## 当前候选协议

未打开队列与已捕获 native 状态明确区分。只有前者要求安装器同时持有同一实际
entry ID 的 `FILE_LOADED` 和 `PLAYBACK_RESTART`，不假定这两项在 main 的投递
顺序，也不延长原 10 秒预算。真实 reader 为 restart 复制前序 START 的 entry ID，
旧安装 owner 的延迟事件不能借用新 owner。Core 在接受收据后按同 restore／队列
token／route 交付一次已验证 restart；已有 native 快照仍等待自己的精确 seek。

未打开媒体的普通恢复不发零 seek；MPV 保存速度与用户后续速度意图独立处理。
显式 seek 改走原精确 seek 屏障，但不能顺带把未改变的保存速度清回 1。
本地同源矩阵如下；没有完整 App 或新同源 CI 通过声明。

事件桥初轮 `voaxntqs` 为 28/0；只撤 reader restart 转发的 `1btps5c6` 为精确
28/8、child 1、验证器 0。两次编译和 source/generated 校验通过。这是暂冻 Core
时的组件证据；并行 Core 保存逻辑后续仍会变化，不称最终全源验证。

## 最终本地矩阵

首轮修补正向 `l9wOtt` 为 64/0，所有退出和 source/generated 校验均为 0；它属于
Core `1603ef22…`／Service `36b2cc5b…`，不是后续最终源身份。

最终 Core `d037183d5ac3ba8c4d398c4f43b5c468ef387bd56e4d81cbf6b53c7dc70d47be`、
Service `c2c9509704b6702da776f0304f51d437d9544b2c46af06a48a320154033a3418`、
Installer `fdc5a77746b98ce140076b95da16502668c0d8e862269882b50c99b8052d4ff5` 下：

| 模式 | artifact 后缀 | 完整结果 | child / runner |
| --- | --- | --- | --- |
| 普通 | mRb8LM | 64/0 | 0 / 0 |
| ASan | XA1ymU | 64/0 | 0 / 0 |
| TSan | CNdDy0 | 64/0 | 0 / 0 |
| unopened-origin | FwqSm0 | 64/2 | 1 / 0 |
| forget-saved-speed | PwbzlX | 64/2 | 1 / 0 |
| forget-speed-intent | bKnFnr | 64/1 | 1 / 0 |
| forget-seek-upgrade | jiD7A9 | 64/2 | 1 / 0 |
| captured-rate-not-authoritative | dUJgLu | 64/1 | 1 / 0 |

前缀为 `build/native-queue-resume.`，串行汇总日志位于
`build/native-queue-resume-matrix.yQp8T0/`。八轮编译均为 0，五个负控验证器均为 0，
严格要求全部四个 CASE、64 项总数、精确失败集合以及 child=1；未知/空表、额外失败、
崩溃和超时不能作为通过。source/generated 前后校验全部通过，无 sanitizer 诊断。
八轮共同 source manifest SHA-256 为
`8e7aa79383ab40c5db81ef7e2615d34f5da73ceb3169b162f331e9f6d3f0fe96`；
其中 Utility 输入为 `abcbe158c1a7b4dc1f9835c816b870e673ae9e631f7f67865a846c5be8afd2cb`，
明确保留后续 App-test 专用路径 seam 修改前的身份。

负控设置示例：

```sh
NATIVE_QUEUE_RESUME_NEGATIVE_CONTROL=unopened-origin bash Tools/NativeQueueResumeTests/run.sh
```

生产 reader 的最终真实事件顺序三模式 28/0 和精确 28/8 负控，另见
`Tools/PlaybackBackendRoutingTests/README.md`。该 probe 已按生产
`MPV_ENABLE_DEPRECATED=0` 编译，不再沿用旧隔离头的默认宏值。
