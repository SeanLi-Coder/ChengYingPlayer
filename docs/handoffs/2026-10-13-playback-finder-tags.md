# 播放中设置 Finder 颜色标签

## 范围与候选

- 稳定基线：`cc39a9dc`，功能分支 `codex/finder-color-tags`。
- 候选：`v0.2.83` / build `94`；当前未发布，最终交付状态须核对完整 CI 与公开资产。
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

发行前还须完整云端构建、真实签名安装、增量全树一致、旧公钥及匿名公开交付核验。
不将合成单元测试中的虚拟发布输出写成真实发布成功。

## 发布基线准备（独立验证工具，未改变 v0.2.83 候选）

功能提交 `ec55ffd0` 已推送主线和不可变标签 `v0.2.83`；标签流水线 `38415549034`
仍在运行，不能据此报告正式发布。后续的验证工具修改不重打包或移动该标签。

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
v0.2.83 发布后仍使用原 `verify_public_release.py` 完成匿名交付、增量还原与冻结 helper 检查。
