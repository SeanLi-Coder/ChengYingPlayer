# Shift 方向键平移（v0.2.84 已发布）

## 范围

- 稳定基线 `5769345c`；分支 `codex/shift-arrow-pan`，版本 `0.2.84` / build `95`。
- 用户要求只按 Shift 配合方向键移动，四向相对旧版全部反转：左键画面向右、右键向左、
  上键向下、下键向上。这是移动观看位置；窗口本身不动，viewport 模型坐标不变。
- 普通方向键继续 seek／调音量，`Command + Shift + 0` 复位不变；支持任意侧 Shift、
  长按与 Caps Lock。Command／Option／Control 组合不触发新平移。
- App 本地键盘 monitor 在 AppKit 前处理事件，因此为平移动作增加 NSControl／NSCollectionView
  及其子视图焦点保护，保留文件列表 Shift 范围多选、outline 导航、slider 操作。
- 去除 bundle 默认配置里被固定平移键覆盖的 Shift 左右字幕跳转映射；不修改用户保存的配置。
- 不合入 `codex/native-playback-core` 实验，不改解码器、模型、下载器、用户媒体或系统权限。

## 验证

本机只运行隔离 fixture，不构建／运行完整播放器、不替换正式安装。

- `bash Tools/VideoToolsTests/run.sh`：三语言各 942 项 UI／快捷键及 132 项任务检查通过，
  rotation coordinator fixture 亦退出 0。
- `bash Tools/VideoViewportTests/run.sh`：英文／简中各 1,389 项，0 失败；使用真实 AppKit
  控件、键盘事件及机械提取的生产处理函数。真实 NSTableView 的 Shift-Down 范围选择通过。
  runner 改用 TestAppWorkspace，所有测试 App 自动精确注销、清理；未重置全局索引。
- Live viewport 使用原五补丁播放库 `2bdcbd6e80d3dd383d1676be907920aa7fb41195d990fb0e5d13f7417a280c3b`
  及现有 FFmpeg 合成 3840×2160 H.264；通过 `CHENGYING_VIEWPORT_PLAYBACK_ROOT` 和
  `CHENGYING_VIEWPORT_FFMPEG` 选定工具，不改变仓库 deps。
  硬件解码 149 项／54 帧、强制软件 GL 加 dropped-reset 重绘回归 149 项／65 帧通过。
  反转 Y 故障对照准确退出 1：实际中心 Y=197.5，预期 161.5，保持原 2 px 容差／期限。
  这是真实桥接／渲染 fixture，不是完整播放器或 M4 AV1 验收。
- 更新策略、交付、增量、受管工作区、公开验证、基线认证与 updater runner 的 Python 测试通过；
  实际 Sparkle 签名 23 项、原生 updater 143 项通过。六种完整 App 签名安装场景由发行 CI 执行。

## 既有 CI 等待器缺陷

本轮核实工具提交 `18f61b55` 的 CI `38422286763` 已失败，而非仍运行：
`Settle paused A-B media` 步骤约 2.55 秒（包含编译）即失败，未到原 8 秒期限。
发现测试 waiter 成功后第二次读取非原子 predicate，会将 true→false 状态变化误判失败。
现真实 live fixture 调用共享 `PlaybackModeWait`，成功样本只读一次，以单调时钟检查前后期限；
超过期限才返回 true 仍失败，所有原成功条件、容差和 8 秒上限不变。
`python3 -B Tools/PlaybackModeLiveTests/run_wait_tests.py` 的 13 项通过；只在临时源码副本
恢复二次读取的负对照恰好两项失败、子进程 exit 1／验证器 exit 0。CI 加入同一纯测试。
旧日志未保留 seeking 和两次采样，不能宣称这是历史失败的唯一原因。
修补后的 `bash Tools/PlaybackModeLiveTests/run.sh` 使用本机现有完整 deps 运行 58 项通过；
发行环境的五补丁库仍须在 CI 重验，不以这一局部结果覆盖历史失败。

## 发布状态

`7bb003e653bdd097c1a4be9cd023444c2b301561` 已发布为
[v0.2.84](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.84)，
北京时间 **2026-10-14 02:11:48** 公开，版本 `0.2.84` / build `95`。
标签流水线 [38437724301](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/38437724301)
三个 job 全部成功：完整 Apple Silicon 构建、原生和真实 4K 渲染回归、六种真实签名安装／重启、
打包后媒体功能、旧公钥验签与增量应用后的全树一致性全部通过。
发布 job `115459395629` 在 `2026-10-13T18:11:55Z` 确认匿名 latest、安装客户端固定 feed、
完整 DMG 和所有增量包的真实下载字节与验证构建一致；八个公开资产齐全。

| 公开载荷 | 字节数 | SHA-256 |
| --- | ---: | --- |
| 完整 DMG | 169,068,160 | `3e4da8a8038555999d05d6a6751ea4eaac53272b8e695a62c3a0470feb08cf0f` |
| build 94 → 95 增量 | 1,130,250 | `f9b912720617b54164ba18f3f95c2ec5ccef019b3b86ff39f980555b8bae462b` |
| appcast.xml | 1,982 | `ecfb4de2d420cd505924a4115ca1bda84f51b99f19bd975499f41c88327bab5a` |

同源码普通主线流水线 `38437724871` 在本记录时媒体 job 已通过，构建 job 仍运行；不把它写成
已完成。上述正式标签流水线的成功结论独立成立。本机未替换正式 App，未额外挂载公开安装包；
完整 App 与匿名载荷交付证据来自上述 CI，不冒称本机完成整包安装复验。历史 v0.2.83 本机忙碌测试卷
问题未在本轮处理，不将其改记为清理成功。

保持 bundle ID、稳定 feed 与 Ed25519 身份，以及更新时用户设置／模型／下载历史保留策略。
本轮唯一发布者为 Codex；没有跳过失败门禁、覆盖已发布资产或移动旧标签。
