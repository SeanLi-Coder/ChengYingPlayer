# Native 续播格式与 MPV 互操作基线

此目录是独立、无 GUI 的真实 libmpv 测试。它验证拟采用的续播记录能否被锁定的 MPV 0.38.0 读取，以及已有 MPV 的关闭、替换和 EOF 保存语义；**不代表 native 播放内核已经实现续播**。生产实现仍见[待实现设计](../../docs/handoffs/2026-10-13-native-resume-design.md)。本测试不导入 `PlayerCore` / native Session，也不替代整窗验收。

## 运行

在仓库根目录执行；默认使用 `deps`，也可以明确指定已经构建、可验证的候选依赖目录：

```sh
bash Tools/NativeResumeInteropTests/run.sh
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" bash Tools/NativeResumeInteropTests/run.sh
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeResumeInteropTests/run.sh
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeResumeInteropTests/run.sh
```

需要 Xcode Command Line Tools、Python 3 和能编码 `libx264` 的 FFmpeg。媒体生成器默认 `/opt/homebrew/bin/ffmpeg`，可通过 `FFMPEG_BIN` 指定；该可执行文件同样记录 SHA-256。

脚本在 `build/native-resume-interop.XXXXXX` 下创建独立证据目录，打印位置并保留成功与失败的原始结果。两份 8 秒、160 × 96、20 fps 合成 H.264 视频没有用户素材。每组检查有自己的 config / watch-later 路径，不使用网站、浏览器、用户播放记录、真实配置或已安装 App。

## 实际参数与覆盖

`Client.swift` 使用真实 `mpv_create` / `mpv_initialize` / `mpv_command` / `mpv_wait_event`，以 `FILE_LOADED`、`PLAYBACK_RESTART`、`END_FILE`、`SHUTDOWN` 和实际属性验证结果。单次等待有 5 秒期限，每个控制组另有 75 秒进程期限；错误事件数量也必须符合预期。

固定选项包括 `config=no`、独立 `config-dir` / `watch-later-directory`、`vo=null`、`ao=null`、`hwdec=no`、`idle=yes`、`pause=yes`、`keep-open=yes`。明确禁用记录内的明文文件名、mtime 检查与忽略路径哈希行为。`save-position-on-quit` / `resume-playback` 按案例设置；初始化后再设置 `watch-later-options=start,speed`，只检查拟互通的两项，不声称覆盖 App 的全部旧状态。

锁定的 Lua-disabled MPV 构建不接受 `load-scripts` 参数。第一次探测因这个无效选项失败，已保留失败证据；正式测试没有通过忽略参数错误继续执行。`config=no` 加独立空配置目录用于隔离。

每个控制组完整执行 83 条断言：

| 场景 | 检查的真实行为 |
| --- | --- |
| 标准记录恢复 | 手工写入首行 `start=2.0` 及 `speed=1.250000`；实际起点与速度恢复，成功加载消费记录 |
| 加载失败 | 不存在的合成目标产生真实失败事件；记录在失败及退出后字节不变 |
| 关闭续播 | `resume-playback=no` 时从零开始、速度为 1，既不应用也不消费旧记录 |
| 原始 stop | `save-position-on-quit=yes` 加 `idle=yes`，直接 `stop` 不保存；随后空闲 `quit` 也不伪造位置 |
| 显式关闭保存 | `write-watch-later-config` 在 `stop` 前调用，保存 2.5 秒与 1.5 倍；随后 `quit` 不覆盖 |
| 直接 quit | 仍有在播文件时 `quit` 保存实际位置与速度 |
| 文件替换 | `loadfile ... replace` 保存旧文件位置，不提前保存新文件位置 |
| 播放列表导航 | `playlist-next` 与 `playlist-play-index` 实际切换文件，不自动保存旧文件位置 |
| EOF 留窗 | 自然 EOF 本身不创建记录；留窗后 `quit` 或显式保存后 `stop`，保存仍可读取的实际末帧时钟 |
| MD5 大小写 | 目录枚举确认 MPV 实际写出大写 MD5；大小写路径查找及小写种子记录的恢复/消费必须符合真实卷语义 |
| 素材身份 | 两份合成媒体在所有操作后保持字节不变 |

`idle=yes` 对应锁定 MPV 的 `player_idle_mode=2`；其 `cmd_stop` 仅在 `< 2` 时走自动保存分支。不能据“退出会自动保存”推断 App 的 stop 同样保存，也不能把 compatibility handoff 误当一次用户关闭保存。具体 pinned 源码位置及 archive SHA 见设计文档。

## 负控与结果验证器

所有负控都完整运行同一组 83 条断言，只改变自身的种子记录、选项或测试命令，不修改生产代码：

| 控制组 | 注入变化 | 预期失败条数 | 预期子进程退出码 |
| --- | --- | ---: | ---: |
| `positive` | 无 | 0 | 0 |
| `wrong-start` | 种子位置由 2 秒变成 3 秒 | 1 | 1 |
| `disable-resume` | 首个恢复案例禁用 resume | 3 | 1 |
| `suppress-explicit-save` | 关闭案例省略显式写入 | 3 | 1 |
| `suppress-quit-save` | quit 案例关闭自动保存 | 3 | 1 |

`verify.py` 校验精确失败项多重集合、83 条输出断言、唯一完成行和真实退出码；崩溃、超时、未完成或其他失败不算负控通过。`test_verify.py` 的四个测试方法及子案例覆盖正常结果与这些拒绝分支，它们只验证结果解析器，不冒充播放测试。

## 2026-10-13 实测证据

使用 `build/native-av1-playback.7FMHum` 候选依赖，无生产文件改动，无 workflow 接入，未启动完整 App：

| 本地保留目录 | 模式 / 结果 |
| --- | --- |
| `build/native-resume-interop.SiXPld` | 初版 setup 失败：不支持 `load-scripts`；不是有效行为验收 |
| `build/native-resume-interop.ILIBEF` | 较早版本普通运行通过；不是下列最终源码身份 |
| `build/native-resume-interop.xmn15o` | 最终普通模式：83/0，四负控为 83/1、83/3、83/3、83/3 |
| `build/native-resume-interop.yFybqd` | 最终 ASan 模式：同上，无捕获到的 sanitizer 诊断 |
| `build/native-resume-interop.JJ2zTX` | 最终 TSan 模式：同上，无捕获到的 sanitizer 诊断 |

最后三个目录的 `source-before.sha256` 完全相同；运行前后源码比较均为空，编译和总 runner 退出码均为 0，依赖与产物校验通过，结果验证器自测均为 4/4。实际加载的 `libmpv.2.dylib` SHA-256 为 `624f1d508511dbad57f40e78698ab7eb30f5875037742c52bec9ab96aba3117f`，所有依赖闭包身份另存于 `dependency-runtime.json`。各子进程的退出码与精确负控结果独立保存。

这三个最终运行中，EOF 两种关闭路径实际读取/写出均为 7.95 秒（该视频末帧时间），没有归零或自动删除。这个数值是当前合成文件的观测，不是其他帧率、流或未来 native 实现的通用常量。

实际卷检测均为 `FILESYSTEM_CASE_SENSITIVE: false`。因此已证明大写文件名事实以及本机不区分大小写卷上的小写读取兼容，**未实测区分大小写卷**。测试为该卷保留独立预期分支，不能把该分支存在当成已经运行通过；同样不能依据本机成功认为所有卷的小写记录都能被 MPV 找到。

## 证据卫生与限制

`run.sh` 复用仓库的依赖闭包验证；运行前后核对头文件、库与参与本测试的源码 SHA，并复核合成媒体及编译产物 SHA。依赖元数据记录 9 个动态库的身份、安装名、rpath 和签名检查结果。失败也保留原始日志与 runner 退出码，不删除或用后续成功覆盖。

ASan / TSan 只插桩当前 Swift 测试可执行文件，现成 libmpv / FFmpeg 动态库没有因此被重新插桩；不能表述为整个播放栈无内存或并发问题。`vo=null` / `ao=null` 不验证渲染、声音、硬解、窗口关闭或 App 与 native Session 的并发生命周期。待实现方案里的 preview baseline、异步快照归属、退出保存屏障、清除 epoch、跨文件回调失效，以及 native queue admission 不覆盖旧位置，仍需分别实现和验证。现有整窗 95 检查把 resume 偏好设为 false，不能用于弥补此覆盖缺口。

该工具只准备下一独立切片的可复现基线。生产内核接线、完整用户流程验收、CI 接入和发布都不能由本目录测试通过自动推导。
