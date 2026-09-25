# JPG 默认截图交接

## 范围与状态

- 基线：`ada35b34`（已验证的 v0.2.40 发布记录）。
- 分支：`codex/jpeg-screenshots`；目标：`v0.2.41` / build `52`。
- 用户要求截图默认生成 JPG；同时覆盖播放器普通截图和原生视频工具逐帧截图。
- 本记录最初写入时实现已完成，正式发布及公开交付仍待 CI 验证；以文末后续证据为准。

## 行为与兼容性

- 普通截图默认 `.jpg`、JPEG quality 100，保持视频帧尺寸，不按播放器窗口缩图。
  不重排已有枚举 rawValue、不强制覆盖偏好；用户明确保存过的 PNG 等格式继续有效。
- 逐帧默认真实 MJPEG/JPG、`q=1`、8 位全范围 4:4:4；输出仍是原视频同级独立目录，
  保留原有起止点、5 秒上限、取消、逐帧数量和不覆盖文件保证。
- 原生面板增加「JPG · 高质量 / PNG · 无损」选择并记住用户选择。PNG 模式保留既有
  8/16 位和透明度处理；浮点或超高位深使用 EXR。图片格式转换默认值不变。
- JPG 仍是有损格式。HDR、透明、浮点和不支持的色彩配置不会静默丢失信息，而是提示
  改选无损模式。高位深 SDR 导出 JPG 会量化至 8 位，UI、进度和完成信息明确说明。
- 明确源 YUV 矩阵／范围到常规 JPEG BT.601 全范围的转换，校验真实编码、完整 JPEG
  标记、可解码帧数、尺寸和像素格式，不通过改后缀冒充 JPG。
- Bundle ID、更新源、签名公钥及自动更新活动保护不变；本轮继续生成并验证上一稳定版的增量包。

## 代码与验证入口

- `iina/Preference.swift`、`MPVController.swift`：普通截图默认值与编码质量。
- `iina/VideoTools/`、三语言 `Localizable.strings`：逐帧格式 UI、偏好与 JSON 请求。
- `Tools/VideoToolsHelper/{media.py,helper.py,PROTOCOL.md}`：格式、色彩及输出验证。
- `Tools/ScreenshotPreferenceTests/run.sh`：隔离偏好／重启保留、真实 libmpv 横竖截图，
  包含 Intel macOS 10.15 类型检查。依赖应用的 `deps`，不读写真实用户偏好或媒体。
- `Tools/VideoToolsTests/run.sh`：真实 AppKit 面板与请求接线，可用
  `CHENGYING_CAPTURE_DIR` 生成布局检查图。测试自身的 PNG 截图不改成 JPG。
- 在 `Tools/VideoToolsHelper` 下用隔离 Python 运行 `python -m pytest -q -rs`；
  `tests/test_frame_formats.py` 覆盖真实 JPG、HDR／透明拒绝、显式 PNG/EXR、旋转尺寸和坏图片。
- `.github/workflows/ci.yml` 接入真实截图测试；`other/build_media_binaries.sh` 要求
  `mjpeg` 编码器及 `scale`、`format` 滤镜可用。

## 限制

合成素材与软件解码验证不等于实体 M4 Max HDR 显示验收。无损图片模式保留现有位深与
透明度保证，不承诺把视频全部 HDR 元数据完整搬到图片 ICC 配置。本轮未更改下载中心，
不新增任何快手真实站点验证结论。

## 本地验证结果

- `bash Tools/ScreenshotPreferenceTests/run.sh`：147 checks，无跳过。
- `CHENGYING_CAPTURE_DIR=... bash Tools/VideoToolsTests/run.sh`：三语言各 634 checks，
  旋转协调器 77 checks、实际任务管理器 23 checks。已查看真实简体中文深色面板截图，
  格式选择、说明和执行按钮均可见，无重叠。
- 使用发行 `deps/executable` 中 FFmpeg／FFprobe 运行 `tests/test_frame_formats.py`：
  38 passed，无跳过。独立复核的奇数尺寸 RGB、灰度、YUV 合成素材也保持正确尺寸。
- helper 全量：249 passed、1 skipped；唯一跳过为当前 Homebrew FFmpeg 缺少既有 AV1
  测试素材编码器（`test_conversion.py:725`），不是 JPG 测试跳过。helper `ruff` 通过。
- 更新测试 `test_updates.py`、`test_delta_builder.py`、`test_delta_assets.py`、
  `test_release_policy.py`、`test_release_delivery.py`：84 passed、164 subtests passed。
- `Tools/AppUpdateTests/run.sh`：143 checks。真实安装 `upgrade`、`tampered-dmg`、
  `delta-upgrade` 三场景均通过：正常安装仅一次重启；坏包拒绝且旧 App 不变；
  增量场景 HTTP 只下载补丁，保留隔离合成偏好、书签、历史及模型标记。
- `typos`、`bash -n`、`git diff --check` 通过。发布 CI 将再次执行完整套件与全部安装场景。
