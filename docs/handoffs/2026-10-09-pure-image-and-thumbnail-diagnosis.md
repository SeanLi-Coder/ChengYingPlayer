# 纯净看图窗口与 Finder 缩略图诊断

基线：`c5975bd092d0ad0444b3eec521418a12403ec9cb`，正式版本 `v0.2.72` / build `83`。
分支：`codex/finder-thumbnails-pure-view`。候选：`v0.2.73` / build `84`。
本轮唯一发布者：Codex；不接管下载模块的既有 Qwen 修补清单。

## Finder：已定位的样本问题与边界

用户已确认 Finder 的“显示图标预览”开启。两个获准检查的 `.jpg` 样本实际都是 PNG；
系统根据后缀报告 `public.jpeg`，原生 `QLThumbnailGenerator` 的 `.thumbnail` 请求返回
`QLThumbnailErrorDomain:0`。不在仓库记录用户的图片、文件名、路径或原始元数据。

同机隔离合成对照，仅改变文件后缀、字节完全不变：

- PNG 使用 `.png` 能生成真实缩略图，复制为 `.jpg` 后失败。
- JPEG 使用 `.jpg` 能生成真实缩略图，复制为 `.png` 后同样失败。
- 正确命名的 JPG、PNG、HEIC、TIFF、GIF、WebP、MP4、MOV 均能生成真实缩略图。
  其中 JPG 和 MP4 的默认打开应用为 ChengYing；反向错误命名的 PNG 默认打开应用为 Preview。

因此不能把这两个样本的问题归因于默认播放器关联，也不能要求用户反复切换图标预览。
以上证明系统缩略图生成的差异，**不等同于 Finder 已实际绘制更新后的图标**。
未修改用户原件、默认应用、Finder 设置或系统索引；没有全局清理缓存。

本机合成 MKV、WebM 也未生成缩略图，但这是单独的格式支持问题，不能拿它替代用户
JPG 样本的根因。没有宣称“所有视频格式缩略图已支持”，也没有加入未验证的缩略图扩展。
删除文档回退图标、覆盖系统 UTI 或直接实例化一个扩展类都不能证明系统扩展生效。
后续若增加扩展，须独立验证现代 `QLThumbnailProvider`、精确 UTI、沙盒解码、
真实系统注册及精确注销；不读取用户其他文件、不自动获取完全磁盘访问权限。

`ImageDocument` 的摘要原来只取文件后缀，导致 PNG 被显示为 JPG；本轮改用 ImageIO
检测的真实类型，允许常见合法别名，对已知不匹配加简短提示。此改变只纠正显示，
不会自动改名、转码或生成用户图片副本。正确后缀的副本须用户明确同意并防覆盖。

## 纯净看图：修补范围

原纯净模式隐藏工具栏，却保留普通编辑界面的 `880×620` 最小尺寸以及隐藏工具栏约束；
竖图窗口因而无法变窄。另实际窗口测试发现，Auto Layout 改变画布尺寸后，旧的
适应窗口缩放值可能没有重新计算，窗口比例正确仍残留黑边。

- 纯净模式解除隐藏界面的布局约束，按图片比例及屏幕可用范围调整窗口，并支持等比例拖动。
- 退出纯净模式恢复普通窗口的尺寸、最小尺寸、缩放策略和 frame autosave；不把临时纯净尺寸写成普通窗口尺寸。
- 画布实际尺寸变化时重新计算适应窗口；不覆盖手动缩放和平移。
- 微型图片在纯净模式下也可适应窗口；普通手动缩放仍以 `64×` 为上限，
  已有更大的适应窗口比例可以连续缩小，切换模式或按放大不会突然反向缩小。
- 原生全屏仍保持图片完整比例。屏幕与图片比例不同时存在留边，不靠拉伸或裁剪掩盖。

## 验证及交付

本机已通过以下检查（仅合成素材与临时偏好，不读取个人相册）：

- `bash Tools/ImageViewerTests/run.sh`：201 项，含 macOS 10.15 Intel typecheck。
- `IMAGE_VIEWER_TEST_FULLSCREEN=1 bash Tools/ImageViewerUITests/run.sh`：原生 UI 200 项、
  真实 ImageIO UI 215 项；实际原生全屏进入／退出／关闭重开，八种图片尺寸、九点边缘像素、
  不同尺寸 TIFF 翻页、手动缩放平移和 frame autosave 恢复已检查。
- `bash Tools/ImageEditingTests/run.sh`：160 项；`bash Tools/ImageRoutingTests/run.sh`：56 项；
  `bash Tools/ImageSlideshowTests/run.sh`：98 项。
- `bash Tools/ImageSlideshowUITests/run.sh`：131 项；`bash Tools/ImageCropTests/run.sh`：通过。
- `bash Tools/UpdateActivityTests/run.sh`：活动屏障 49 项、真实 helper 退出 24 项。
- `test_release_policy.py` 和 `test_release_delivery.py`：合计 39 项、74 个子测试；
  `test_delta_assets.py`：14 项、21 个子测试。
- 使用锁定的 Sparkle SDK，`test_updates.py`：23 项；`test_delta_builder.py`：10 项，
  包括临时真实签名、完整包／增量全树一致、损坏拒绝及受管工作区清理。
- `bash Tools/AppUpdateTests/run.sh`：143 项原生 updater 检查，通过 `TestAppWorkspace`
  指定独占 `.noindex` 临时目录运行，退出后精确注册检查及工作区清理通过。

修补过程中，真实测试曾捕获 AppKit 不允许将读回的未设置比例 `0:0` 直接赋回的问题，
改为恢复 `contentResizeIncrements` 清除比例；未通过取消断言掩盖。后端别名测试曾有
大小写不敏感文件名冲突和 HEIC／HEIF 类型预期过严，已修正独立夹具命名及合法家族预期。

本地相关回归已通过；完整发布构建及公开交付待执行，候选尚未发布。
不能把局部检查、Git 标签或本地构建写成正式发布完成。
