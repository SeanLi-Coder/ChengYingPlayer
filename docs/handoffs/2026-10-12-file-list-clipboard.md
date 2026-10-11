# 文件列表剪贴板操作

## 范围

用户要求给播放器文件列表增加右键复制、剪切、粘贴，并支持 Mac 快捷键。
本轮只改原生视频文件夹浏览器和图片文件夹／图片列表；不改下载器、不重新引入专用登录窗口，
也不改原有播放队列的引用型复制、剪切、粘贴语义。本轮发布者为 Codex。

- `⌘C` 复制，`⌘X` 标记剪切，`⌘V` 粘贴；还支持 Finder 风格的 `⌘C` 后 `⌥⌘V` 移动到此处。
- 支持多选以及文件夹。右键不触发图片切换；菜单捕获打开时的文件身份及目标目录，
  排序、刷新或导航不能悄悄改变菜单实际操作的文件。粘贴目标是当前浏览目录。
- 复制使用标准文件 URL 剪贴板类型，可与 Finder 交换；程序内剪切只记录意图，粘贴成功才移动。
  不读取测试以外的用户剪贴板做验证。
- 同名文件不覆盖；部分失败分别报告，失败的剪切项保留可重试。成功项刷新相关目录，
  已打开图片重新绑定新路径，包括通过父目录别名打开的图片。
- 播放中的队列、正在编辑的图片和处理中媒体受保护；移动前应关闭相关播放／编辑，
  或切换到不使用这些源文件的播放目录。复制仍可进行。移动期间拒绝新打开／切换操作，
  不把长时间复制当成禁止视频播放的理由。
- 操作在后台执行，完成前持有更新工作锁；普通退出也会明确提示等待，不中途终止传输。

## 文件安全和已知限制

`MediaFileTransfer` 采用 descriptor-relative 文件操作、身份快照和排他重命名；复制先写入新建的
私有暂存目录，源数据与目录快照复核后才发布。文件内容及正常文件／目录的 Finder 标签和元数据
用系统复制 API 保留，不重编码媒体。只清理本次创建且身份仍符合的暂存内容，不删除用户源文件。

跨磁盘移动暂不支持，直接报错并保留原文件；可先复制，核实后在 Finder 中管理原件。
同一目录粘贴不会自动创建带编号的重复文件；符号链接根项、特殊设备以及含挂载子树的复制不支持。
文件夹内部符号链接只复制链接，不跟随到外部目录。
其他进程同时改名或写入时保守报错；不把非协作进程的并发修改说成绝对原子事务。

播放队列引用修复通过 `MediaPlaylistRelocation` 根据稳定 entry ID 核实每一步；
队列同时改变时停止，不凭旧行号删除项目。只有确认为本次插入、且未开始播放的引用才允许回滚。

## 本轮验证

全部文件操作测试使用随机临时合成目录、具名剪贴板；不移动用户图片／视频，不修改系统权限。

- `bash Tools/MediaFileTransferTests/run.sh`：634 项检查通过，含实际文件内容、标签、
  同名、祖先目录、失效身份、别名、24 路同名竞争和源文件交换压力测试。
- `bash Tools/MediaFileActionsTests/run.sh`：140 项通过，含真实 NSWindow 快捷键分派、
  焦点隔离、菜单快照、多选、失败重试、播放保护、移动／复制工作锁和队列并发修复。
- `bash Tools/SilentVideoOpenTests/run.sh`：362 项真实 libmpv 检查通过，包含新增命令入口保护。
- `PLAYLIST_REQUIRE_LIVE_TESTS=1 bash Tools/PlaylistPlaybackTests/run.sh`：3,854 项策略、51 项真实 libmpv 检查通过。
- `bash Tools/MediaFolderBrowserTests/run.sh`：三种语言各 86 项通过；
  `bash Tools/PlayerChromeIntegrationTests/run.sh`：618 项通过，小窗口仍保留完整文件行。
- `bash Tools/ImageViewerUITests/run.sh`：213 项原生 UI、253 项真实 ImageIO 检查及 Intel typecheck 通过，
  包含别名路径、幻灯片保护和不会被解码完成覆盖的错误提示。可选原生全屏切换未启用。
- `bash Tools/AppUpdateTests/run.sh`（指定现有 Sparkle framework）：143 项通过；runner 负对照另有 7 项通过。
- `bash Tools/ImageSlideshowUITests/run.sh`：131 项通过。
- `Tools/AppUpdateIntegrationTests/run.py` 的完整包场景已通过：真实签名、可见下载、空闲等待、
  实际替换并仅重启一次，合成偏好、书签、历史、模型保持一致；受管测试 App 清理成功。
- 播放队列原有测试：两种语言各 361 项 presentation、109 项 controller，以及 25 项引用操作通过。
- ImageRouting 56、PlaybackLifecycle 76、PlaybackUIPerformance 32、PlaybackMode 126 项及进程间设置恢复通过。
- 更新 policy／delivery／delta／public workspace：64 项、110 子测试通过；
  signed update／delta builder：33 项、69 子测试通过。

测试曾发现新增状态 footer 挤压小尺寸列表，已改为复用目录 header；原严格布局断言全部保留。
真实图片双击测试另发现未获得 key window 的首点击被 AppKit 用于激活；测试增加 active/key 屏障、
恰好一次 toggle 和真正最大化断言，未修改生产图片几何，也未放宽恢复尺寸要求。
播放队列后台追加在移动期间保守拒绝且不排队回放；路径修复有唯一显式入口，不影响普通复制时的播放。

候选版本为 `v0.2.78` / build `89`；剩余增量／拒绝安装和发行验证结果将在发布前补齐。
以上不等于正式版本已发布。
本机只有 Command Line Tools，没有完整 Xcode，完整 App 编译与打包依赖已有 GitHub Actions 门禁。

## 后续协作注意

不要让文件表快捷键进入原有播放队列表，也不要把播放队列的“移除引用”改成删除磁盘文件。
不要放宽同名保护来实现覆盖；若以后要加覆盖、跨磁盘移动或取消传输，需单独设计恢复和验证路径。
新建测试 App 必须使用 `TestAppWorkspace`；不要在用户系统留下测试应用注册或执行全局索引重置。
