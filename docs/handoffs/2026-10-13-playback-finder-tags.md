# 播放中设置 Finder 颜色标签

## 范围与发布状态

- 稳定基线：`cc39a9dc`，功能分支 `codex/finder-color-tags`。
- 已发布：`v0.2.83` / build `94`，北京时间 **2026-10-13 23:32:26**。
  云端构建、真实安装与发布检查成功；本机公开验收的载荷、签名、增量和冻结 helper 已通过，
  但最后测试卷正常卸载失败，整轮退出非零，不能表述为本机完整验收成功。
- 不合入实验 native 播放内核，不改变播放依赖、更新身份、公钥或保存的偏好。
- 不读取／修改用户真实媒体作为测试，不修改系统隐私权限，不替换本机正式安装。

## 实现

默认底部布局右上角新增标签图标，文件列表仍位于最右。七种颜色可同时存在，已有颜色
勾选且不可重复添加；已有每个标签按名称提供精确移除入口，无清空全部按钮。
菜单异步读取、写入都不暂停／重新打开视频，不 seek，也不重排队列。

`PlaybackFileTags` 以后台串行队列读取／修改真实 named-tag xattr，主队列回调。
固定菜单读取时的文件描述符，核对设备、inode、出生时间、内容大小与修改时间，
读回已写标签确认成功。符号链接、祖先符号链接、硬链接、特殊文件、异常 plist、
权限错误与已观察到的外部改动均拒绝写入；同名但不同颜色（含无色）的标签冲突也拒绝。
只改 `com.apple.metadata:_kMDItemUserTags`，不改变内容字节、mtime、其他 xattr 或文件权限。

`PlaybackFileTagController` 固定 URL 和媒体代际，菜单打开后换片会拒绝旧动作；
点击已接受的写入仍针对旧文件，不会改到新视频。成功后发布独立元数据通知，
仅刷新包含该文件的播放列表和对应目录；保留多选与筛选，不调用移动文件通知。
写入持有更新活动屏障；退出和最后窗口关闭退出均检查 pending write，避免中途终止。
控制条交互使用专属窗口代际的一次性 lease，关闭／重开后的旧回调不能解除新拖动状态。

## 明确保留的边界

- xattr 无 compare-and-swap，最终比较到写入之间不能承诺绝对排除 Finder 同时写入；
  检测到写后变化仅提示核实，不回滚覆盖外部的新标签。
- 菜单快照绑定的是菜单读取时的文件，不是从播放器反查开片时 inode。
- 旧式 FinderInfo 色标有意保留并在菜单提示；移除最后一个现代标签后，列表可能重新
  显示旧式颜色，不能宣传为清除全部历史颜色。旧式标签需在 Finder 中管理。
- 本机合成文件经 Apple `tagNames` API 和现有生产列表读取验证，不等于用户机器上
  Finder 的物理图标重绘验收，不承诺所有远程文件系统支持。
- 完整播放器只由 CI 构建／验证；本机只运行 CLI 和隔离 AppKit fixture。

## 本地验证

- `bash Tools/PlaybackFileTagTests/run.sh`：336 项通过；独立复跑同样 336 项通过。
- 同一测试 `PLAYBACK_FILE_TAG_SANITIZER=address` 和 `thread`：各 336 项通过。
- `python3 -B Tools/PlaybackFileTagTests/negative.py remove-color` / `skip-conflict` /
  `skip-readback`：精确注入控制分别 332/1、336/4、336/1，控制器确认预期失败且源码未变。
- `python3 -B Tools/PlaybackFileTagTests/test_integration.py`：4 项通过，覆盖三语文案、
  Xcode Sources、退出保护先于关闭／更新、CI 入口。首次捕获新 name-conflict 的三语缺项，
  已补齐后复跑通过，未删除断言。
- `bash Tools/PlaybackFileTagUITests/run.sh`：39 项通过，真实存储、NSMenu 动作、换片、
  并发标签变化和读菜单时关闭窗口。首轮临时 `/var` 祖先链接被正确拒绝，
  仅将 fixture 移至 owned build 路径，未放宽生产链接检查。
- `bash Tools/PlayerChromeIntegrationTests/run.sh`：885 项通过，含窄窗／全屏／布局反复切换，
  新按钮仍不遮挡列表，未恢复用户取消的中间播放按钮。
- `bash Tools/PlayerChromeLifecycleTests/run.sh`：188 项与 4 项全屏源码检查通过；
  独立 review 发现并修复跨窗口关闭的交互计数问题，新增 3 项生产路径检查。
- `bash Tools/MediaFolderBrowserTests/run.sh`：英文／简中／繁中各 98 项通过，
  覆盖标签通知刷新、多选保留、活动颜色过滤与无关目录不刷新。
- `bash Tools/PlaylistFilterTests/run.sh`：66 项通过；元数据原有测试通过。
- `bash Tools/PlaylistPresentationTests/run.sh`：英文／简中各 361 项展示和 109 项控制器检查，
  另 25 项操作检查通过；`MediaFileActionsTests` 140 项、`PlayerChromeInteractionTests` 40 项通过。
- 更新策略 19 项、交付 20 项、增量资产 14 项、真实 Sparkle 签名 23 项、原生 updater
  143 项通过；安装／重启与公开交付仍由后续完整发行验证确认。
- 新组件 Swift 5 arm64 macOS 12、存储与 lifecycle 的 Intel macOS 10.15 typecheck 通过。
- 独立 review 无剩余合入阻断项；全部 fixture 使用合成文件，没有读取真实用户视频。

上述本地测试不替代完整云端构建、真实签名安装、增量全树一致、旧公钥及匿名公开交付核验。
后续真实发行结果见下文；不将合成单元测试中的虚拟发布输出写成真实发布成功。

## 发布基线准备（独立验证工具，未改变 v0.2.83 候选）

功能提交 `ec55ffd0` 已推送主线和不可变标签 `v0.2.83`；基线提取时标签流水线
`38415549034` 尚未完成。后续的验证工具提交 `18f61b55` 不重打包或移动该标签。

本机以原 `verify_public_release.py` 复核 v0.2.82 时，系统 CA 配置修正后，匿名 API、
完整 DMG／增量实际下载以及旧公钥验签已完成，但旧 v0.2.81 测试卷仍挂载，
再次挂载失败使整轮退出非零；新 v0.2.82 卷已正常卸载。原失败证据和旧忙碌测试树保留，
未强制卸载、停止安全进程或替换验证器结果。

新增受版本管理的 `other/verify_release_base.py` 仅准备下一次验证所需的可信基线：
用独立 v0.2.81 原始 Info 的公钥先认证 v0.2.82 feed 与完整 DMG，然后在新的
`TestAppWorkspace` 只读挂载 v0.2.82，核对实际版本、build、更新身份、ARM64 和严格签名，
导出原始 Info 字节。它不执行完整 App 或 helper，不替代正式公开安装验证。
新增 16 项边界单元测试和原公开工作区 11 项均通过；独立 review 未发现阻断。
真实基线提取已通过，报告为 `verified-base`，卸载和测试 App 清理均成功：
`build/ReleaseVerification.noindex/release-v0.2.82-base.sin5b761/base-verification.json`。
完整 DMG SHA-256 为 `be01ef4e17b6bbce33d10a4ed0d68b7834139563b89e79d56979e241bd7a7b75`，
原始可信 Info SHA-256 为 `f3d0afcb472ac00d67a664d4ed2fd7a219119455ae0903a7b7cce5a62d42e550`。
此结果只是已认证的完整包基线，不把 v0.2.82 未完成的安装／增量／公开全流程改写为成功。
v0.2.83 发布后仍使用原 `verify_public_release.py` 进行匿名交付、增量还原与冻结 helper 检查。

## 正式发行与本机公开验收

- 发行地址：[v0.2.83](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.83)。
  不可变标签仍为 `ec55ffd07892535afa84f6a91ce6386c55bedcaf`，没有重复发布或覆盖资产。
- 标签流水线 [38415549034](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/38415549034)
  的媒体测试、完整 Apple Silicon 构建和发布三个 job 全部成功，包括六个真实签名更新安装场景、
  打包后媒体回归、增量还原全树一致、旧公钥验签，以及发布后的匿名交付检查。
- 原主线候选流水线 [38415547873](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/38415547873)
  两个验证 job 成功，发布 job 按分支设计跳过。等该流水线结束后，工具提交 `18f61b55`
  经远端祖先检查 fast-forward 到主线，未合入 native 内核实验。
- 后续工具主线流水线 [38422286763](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/38422286763)
  在本记录时仍运行；它不是上述已发布 tag 的构建，不将尚未结束的检查写成通过。

本机使用 Python 3.13、系统 CA、直连公开 GitHub 域名运行原验证器，命令参数为：

```sh
SSL_CERT_FILE=/etc/ssl/cert.pem \
NO_PROXY=api.github.com,github.com,release-assets.githubusercontent.com \
no_proxy=api.github.com,github.com,release-assets.githubusercontent.com \
/Library/Frameworks/Python.framework/Versions/3.13/bin/python3 -B \
  other/verify_public_release.py --tag v0.2.83 --build 94 \
  --previous-directory build/ReleaseVerification.noindex/release-v0.2.82-base.sin5b761 \
  --delta-tool ../chengying_player/build/sparkle-local-updater.tmslcJ/sdk/bin/BinaryDelta \
  --helper-build-id 48af0bac450b48b5ba58ae0efc6b333ea9b7480e593bdf73ffc24b06ec7ec517
```

命令从 `chengying_player-finder-tags` 仓库根目录运行，`--delta-tool` 为本轮现有 Sparkle SDK
工具的相对路径，不是新下载脚本；在其他机器复验时需提供各自可信 SDK 的对应路径。
真实报告目录为 `build/ReleaseVerification.noindex/release-v0.2.83-public.kg0qq3e3/`。
匿名 latest API、客户端实际 feed 与固定标签 feed 一致、完整 DMG 与全部增量的实际字节数／
SHA-256、上一版本可信公钥认证均通过。两个认证后的 DMG 只读挂载成功，真实 Info／ARM64／
严格代码签名通过；build 93 → 94 增量还原的完整签名应用与完整 DMG 的文件树一致。

| 公开载荷 | 实际大小 | SHA-256 |
| --- | ---: | --- |
| 完整 DMG | 169,058,237 字节 | `f1ecc14a653cfdd887a7086e00f341d662a49cc09c450e39d984a5ebc3981d17` |
| build 93 → 94 增量 | 1,397,678 字节 | `65eb96ca54a43f1585b92e4080a29ca11d51498c97cc8098875cdd64bddc3a23` |
| appcast.xml | 1,982 字节 | `d32f4b1ff35112a6260e11cb47c8fff57469fecfb67c2e2c2eb7105d2ece3151` |

隔离的冻结 helper `--self-test`、本地诊断 API smoke、精确 Dolby Vision 8.1／8.4 与 HDR10+
剪辑合成用例全部通过；实际诊断身份为播放器 `0.2.83` / `94`，helper build ID 与上方一致。
没有执行完整播放器、读取浏览器账户或真实用户媒体，也没有替换本机正式安装。
认证后导出的原始 `trusted-app-info.plist` SHA-256 为
`2bd39e8e87bf6da2690a5b0d532162ad2831684af110aa5d601ca9c69603b8fc`。

**未完成的清理边界：**所有载荷、文件树和 helper 检查之后，原验证器正常卸载本轮
`old-volume`（v0.2.82）和 `new-volume`（v0.2.83）均返回 exit `16`；各自额外正常重试一次
仍明确返回 `Resource busy`。普通 `lsof` 在这两个精确卷上没有显示可见占用，不能据此断言
某个具体进程负责。`TestAppWorkspace` 正确拒绝删除仍挂载的目录，保留失败标记和证据，
本轮总退出码 `1`，**没有 `verification.json` 成功报告**。
不强制卸载、不终止安全／系统进程、不改系统权限；旧 v0.2.81 忙碌卷完全未碰。
下载归档、校验文件、原始可信 Info 和 helper 日志均在 disposable App 目录之外保留。
后续应在本轮卷可正常卸载后按受控工作区流程收尾，再重新运行原严格验证；
不可通过伪造报告、删除失败标记或放宽清理断言改写此次结果。
