# Native 续播保存组件回归

验证 `iina/NativePlayback/NativePlaybackResumeStore.swift` 的真实磁盘发布、纯所有权策略和标准 MPV 记录互操作。组件不读取 `UserDefaults`、用户媒体、历史或真实播放位置；调用方负责先取得当前媒体对应的有效快照，再提交票据。**这里通过不等于整个 App 或 native 续播已经验收。** 关闭、换片、预览恢复、退出等待与旧记录 admission 仍需要各自接线测试。

## 组件约定

```swift
let store = NativePlaybackResumeStore(rootURL: directory, initiallyEnabled: true)
let ticket = store.begin(digest: uppercaseMD5, owner: ownerID, mediaGeneration: generation)
store.enqueue(ticket!, position: position, speed: speed) { result in }
store.invalidate(ticket!)
store.setResumeEnabled(false)
store.performClear(operation: { /* Perform the authorized watch-later clear. */ }) { result in }
store.drain { /* All previously submitted work has delivered its completion. */ }
```

示例中的强制解包只用于展示类型关系，实际接线必须处理 `begin` 返回 `nil`。除 `setResumeEnabled` 可由任意 KVO 线程调用外，入口均要求 main；所有完成回调异步在 main 恰好交付一次。不要阻塞 main 等回调，退出流程需要保留异步退场所有权直至完成。

- 摘要必须恰为 32 位 ASCII 大写十六进制，组件不自行读取媒体路径或计算文件身份。票据包含独立 store ID、owner UUID、媒体 generation、单调 serial 与 clear epoch；同一摘要只承认最新票据，旧票据不能通过迟到 invalidate 取消新票据。
- `start` 必须有限且非负，`speed` 限定在 0.5–2。内容只有首行 `start` 和次行 `speed`，不写明文媒体路径、音量、A/B 或其他临时 UI 状态。Double 格式与系统 locale 无关。
- 写入在串行 worker 上执行。临时文件使用 `O_EXCL` / `O_NOFOLLOW`、0600 权限和独立随机名称，完整写入并 `fsync` 后才通过 `linkat` 原子、不覆盖发布。
- root 与所有祖先目录均以 `O_NOFOLLOW` 逐级打开；root 须属于当前用户且不能为组／其他用户可写。组件不创建、chmod 或“修复” root。提交前再次检查 root inode 与临时 inode；未知大写／小写记录、目录或 symlink 一律保留。不要把配置位置的 symlink 失败静默改成写入另一个位置。
- 最终 `linkat` 与最后一次策略检查共享短锁。同步 opt-out 返回后，旧的排队记录不能再发布；重新打开偏好也不复活旧票据。已经在 opt-out 前完成的记录不会被自动删除。
- `performClear` 立即关 gate、递增 epoch 并废弃旧票据；在相同 worker 排在此前磁盘工作之后执行调用者提供的清理闭包。gate 保留至 main 完成通知前，并由独立 clear ID 处理重复清理。清理失败如实返回错误，不复活旧票据，也不擅自改变 resume 偏好。组件自身不递归删除任何目录；只协调 native 写入，不保证阻止其他 MPV 实例或外部进程写入。
- 结果只含 `.saved`、`.conflict`、`.stale`、`.disabled` 或 `.ioError(errno)`；清理独立返回 `.cleared` / `.ioError(errno)`。不在结果中携带路径或底层错误全文。

## 运行

在仓库根目录使用已验证的 libmpv 依赖；默认 `deps`，以下为本次隔离候选：

```sh
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" bash Tools/NativeResumeStoreTests/run.sh
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeResumeStoreTests/run.sh
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeResumeStoreTests/run.sh
```

需要 Xcode Command Line Tools、Python 3 和 FFmpeg 的 `libx264` 编码器。媒体生成器默认 `/opt/homebrew/bin/ffmpeg`，可通过 `FFMPEG_BIN` 明确指定；记录其 SHA。每次运行创建独立 `build/native-resume-store.XXXXXX`，保留所有源码、产物摘要、真实退出码和日志，不复用或清除旧证据。测试拒绝在 root 用户下用写权限测试假装真实普通用户权限行为。

## 实际覆盖与负控

普通存储进程执行 **158 条**固定断言，使用真实、当前测试独占的临时目录：

- 摘要、有限数值、白名单内容、独立 owner/generation/epoch、多 store 及重复 clear 的纯策略。
- 实际 0600 文件、单一 regular inode、临时清理、一次性提交和错误数字拒绝。
- 未知大写／小写文件、真实和悬空 symlink、同名目录、root/祖先 symlink、缺失 root、实际 `EACCES` 与组／其他用户可写 root。
- 用受控 worker 屏障停在完整临时写入之后、正式提交检查之前，真实验证取消、其他线程 opt-out、opt-out 后重新启用、新 owner、外部冲突、root 置换及临时 symlink 置换。屏障没有伪造保存结果，生产 gate 和 POSIX 操作仍实际执行。
- 新旧 owner 的真实磁盘字节归属；清理关 gate、旧 worker 收尾、off-main 清理、旧票据不可复活、失败清理、重复清理和清理不改 opt-out。
- 主队列恰一次回调；用 SHA-256 检查每个受保护的合成旧文件字节不变。

额外的 **8 条真实 MPV 检查**不定义测试宏：原样生产 Store 向独立 watch-later 目录写记录，冻结 MPV 0.38.0 实际加载合成 H.264 文件，恢复 2.5 秒及 1.25 倍并消费记录，随后正常退出。`vo=null` / `ao=null` / `hwdec=no`，无 App、GUI 或用户配置。只读复用 `Tools/NativeResumeInteropTests/Client.swift`，未改变既有 83 项 interop 夹具。

三组定向负控各完整运行同一组 158 条断言：

| 控制组 | 变化 | 精确失败数 |
| --- | --- | ---: |
| `bypass-final-gate` | 只跳过最终提交前的策略检查 | 9 |
| `private-fields` | 输出中额外加入 volume | 4 |
| `overwrite-unknown` | 取消既有记录保护并改为覆盖式 rename | 14 |

`verify.py` 要求精确失败多重集合、完整断言条数、唯一完成行和真实子进程退出码；不能用崩溃、超时或意外失败冒充有效负控。其 4 项自测验证正常输出和拒绝路径，自测只证明结果解析，不替代文件/播放测试。每个存储控制组 45 秒整体限制，每次异步等待 5 秒；真实 MPV 进程另有 30 秒限制。

## 2026-10-13 冻结结果

生产 Store SHA-256：`776eae5caea1ce313ea4df2d9f5825642f3e9b4b56c51e281d21546453194712`。

| 本地证据目录 | 模式 | 存储正向 / 真实 MPV | 负控 |
| --- | --- | --- | --- |
| `build/native-resume-store.iveFB0` | 普通 | 158/0 + 8/0 | 158/9、158/4、158/14 |
| `build/native-resume-store.eF3xOH` | ASan | 158/0 + 8/0 | 同上 |
| `build/native-resume-store.VC5PtC` | TSan | 158/0 + 8/0 | 同上 |

三个目录的源码清单相同，源码前后对比为空，全部 runner / 正向 / 实际 MPV 退出 0，负控子进程精确退出 1。源码、变体、可执行产物、合成媒体与依赖闭包 SHA 校验通过；无捕获到的 sanitizer 诊断。无测试宏的 Intel macOS 10.15 typecheck 通过，结果验证器 4/4。libmpv SHA 为 `624f1d508511dbad57f40e78698ab7eb30f5875037742c52bec9ab96aba3117f`，完整 9 库身份在 `dependency-runtime.json`。

主代理另以同一 Store 独立普通复跑 `build/native-resume-store.OSuCWl`：158/0、真实 MPV
8/0，以及三个精确负控 158/9、158/4、158/14；runner 0，源码、产物与依赖校验通过。
这次复核不扩展到 Core 或完整 App。

更早的 `t2wbtJ`（143 项）、`gtybzy`（158 项但尚无最终严格 verifier / 实际 MPV）及 `utPUe7`（严格 158+8，runner 尚未补每次编译退出码文件）保留，不与上述最终同源证据混用。本组件本轮没有吞掉失败后原样重跑的记录；有意注入的负控失败是可重复证据，不是生产运行失败。

## 尚未证明的范围

该套测试不启动 App、不读取用户媒体或真实 watch-later，也不修改 Xcode 工程／workflow。Store 不负责选择关闭/替换/EOF 的业务保存时机，不负责 preview baseline、worker 时间采集、旧记录读取、LastPlayed 或历史偏好。相应 Session/Core/Service 接线必须另行验收；未完成的[续播设计](../../docs/handoffs/2026-10-13-native-resume-design.md)不能因本套检查通过就整体改为已完成。

ASan / TSan 只插桩当前 Swift 测试可执行文件，现成 libmpv / FFmpeg 动态库未重新插桩。未验证渲染/声音、目标 M4 或硬解、断电/强杀后的持久化、恶意同 UID 进程在单次系统调用间替换私有目录。当前卷不区分大小写；保存前会显式检查大小写两个名字，但在区分大小写卷的真实互操作仍未实测。原子发布不是任意崩溃后清理临时文件的保证，不应扩大为整个播放栈没有竞态或已可发布。
