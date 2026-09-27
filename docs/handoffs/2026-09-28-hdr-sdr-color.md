# 2026-09-28 HDR / Dolby Vision 播放色彩修复

## 范围与基线

- 基线：`c3261c71`，上一稳定版 `v0.2.41` / build `52`。
- 本轮只修复播放器的色彩解释和显示状态，不重编码或修改用户源视频。
- 目标版本：`v0.2.42` / build `53`。发布状态以本文末尾的交付记录为准；
  代码、测试或标签本身不代表已公开发布。

## 根因与处理

用户提供的是 10-bit HEVC、BT.2020 / HLG、Dolby Vision Profile 8、
compatibility ID 4 的视频。固定的 mpv 0.38.0 / libplacebo 6.338.2 在读入
Dolby Vision metadata 后把色彩标记映射为 PQ；旧 OpenGL 路径不支持对应 reshape，
却没有恢复兼容的 HLG 基础层，导致亮度和颜色错误。不能用统一降低亮度或强制所有视频 HLG 处理。

- `other/patches/mpv-0.38.0-dovi-base-layer-colors.patch` 回移上游基础层回退，
  完整出处和本项目对 0.38 的适配见补丁头及 `other/patches/README.md`。
- 保留原始原色、传递函数、矩阵、HDR 元数据与 light model；覆盖属性复制、
  AVFrame 来回转换和 format filter。兼容基础层改变时重新配置，避免沿用前一组色彩参数。
- 在共享 OpenGL 初始化中恢复基础层，保留原始帧与 Dolby Vision side data，
  不改变公开 libmpv ABI，不改变固定依赖版本，不宣称新增完整 Dolby Vision 动态处理。
- `VideoView.setICCProfile()` 每次回到 SDR 都重设渲染参数，不再只依赖 layer 色彩空间变更。
  只有真实应用屏幕 ICC 后才标记该显示空间；ICC 关闭、失败或没有屏幕时使用明确 sRGB 回退。
- `PlayerCore.playbackRestarted()` 在新文件首帧就绪时同步色彩，覆盖相同色彩标签换片和早到的
  属性通知。普通 seek / A-B 循环不重复刷新 ICC。
- 默认 HDR 关闭与用户明确保存的开关、截图格式、自动更新及其他设置均保持不变。

## 回归入口

```bash
bash Tools/HDRColorStateTests/run.sh
bash Tools/HDRPreferenceTests/run.sh
bash Tools/HDRSourceTests/run.sh
bash Tools/HDRRenderingTests/run.sh
CHENGYING_TEST_SOFTWARE_GL=1 bash Tools/HDRRenderingTests/run.sh
bash Tools/ICCProfileTests/run.sh
```

`HDRSourceTests` 需要 Meson / Ninja 和已构建的固定播放依赖，可以传入独立依赖目录。
它重新解出校验固定的原始源码，证明原版重现问题，再编译实际 `mp_image` 与 format 参数函数，
在 ASan / UBSan 下检查合成 AVFrame、HLG / PQ / SDR、复制、round-trip 与渲染重配置。
`HDRRenderingTests` 无需 FFmpeg 命令行，直接用播放栈 FFmpeg 生成 10-bit 灰阶视频，
通过实际 CGL / libmpv 检查像素与 ICC；过期输出参数恢复由 `HDRColorStateTests` 检查。
CI 不跳过实际渲染。

用户原片的复现和修复验证仅在本机忽略的临时构建目录进行。原片只读，
参考副本去掉 RPU 但保留 HLG 基础流和时间戳，用于同帧对照。
不将个人媒体、截图、文件名、哈希或日志上传到 GitHub。

## 验证限制

- 合成灰阶不代表广色域色准校准，也不含真实 Dolby Vision RPU；源码回归与私有样本对照互补。
- 当前 OpenGL 路径使用兼容基础层，不承诺无兼容基础层的 Dolby Vision Profile 5 完整还原。
- 本机 Apple M2 Pro 的离屏软件／VideoToolbox 验证不等于用户 M4 Max 实体 HDR 屏幕验收。
- 源视频的尺寸、音频和媒体文件不变；修复只影响显示解释。

## 交付记录

本机已通过：

- 实际重新构建完整固定播放栈与四份补丁；播放能力检查及依赖签名通过。
- 源码回归：原版失败、最终补丁版 154 项 AVFrame 检查及真实 format 参数函数通过，
  ASan / UBSan 无错误；源码获取 27 项、发行完整性回归 32 项通过。
- 新文件 / ICC / SDR 状态 149 项、HDR 偏好 42 项、窗口尺寸 70 项、截图 147 项通过。
- 新库实际 ICC 检查 6157 项 / 12 次渲染，旋转 teardown 的十种组合通过。
- 新库合成 SDR / PQ / HLG 像素测试在 Apple M2 Pro CGL 和 Generic Float CGL 下均通过。
- 用户只读原片在 0、3.001666、10.003333 秒，软件、VideoToolbox、VideoToolbox-copy 共
  九组同帧对照全部通过：修复后与纯 HLG 基础流 framebuffer 逐字节相同；
  每组核实实际库路径、`hwdec-current` 与时间戳。纯 HLG 基础流的新旧库像素也逐字节相同。
- 更新策略 / 交付 / 增量资产共 53 项、增量构建 8 项、原生更新 143 项通过。
  真实签名完整包安装和增量安装分别验证了只请求对应载荷、可见进度、空闲替换、
  一次重启与设置 / 历史 / 模型保留；使用临时测试 App，未改用户安装。
- Ruff、typos、shell 语法和差异检查通过。

本机仅有 Command Line Tools，完整 App 由 CI 编译和验证。本机既有 viewport suite
两次出现测试 App 无法成为 active 的环境失败（1055 项中 1 项），不视为本机通过，
未跳过或修改检查；正式 CI 已完成并通过原检查。

### 正式发布与公开交付

`v0.2.42` / build `53` 已于 **北京时间 2026-09-28 02:30:08** 正式发布，
标签提交 `4f7a512461bff11d15e639514a45d064d7952677`。

- [正式标签 CI 36338067127](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36338067127)
  全部通过，包含新增色彩检查、完整 App、实际更新安装、旋转与循环，以及公开发布验证。
- [主线 CI 36338063629](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36338063629)
  第二次执行全部通过。首次 x264 下载只收到 7438 字节异常响应，原 SHA-256 校验正确拒绝；
  本机重新下载的官方归档与既有缓存逐字节一致，原版本／URL／哈希未改，重试恢复。
  未关闭 TLS 或校验，未重建或移动标签。
- 八份发行资产齐全，完整包与从 build `52` 起的增量包都可公开匿名下载。
  `/releases/latest` 与 App 内固定 feed URL 指向 v0.2.42；固定 feed 与标签 feed 字节一致。
- 使用此前已验证 v0.2.41 的公钥验证新 feed、完整 DMG 和全部增量包；实际下载的大小与
  SHA-256 同时匹配 checksum 文件和发行资产 metadata。
- 实际应用公开增量包，验证还原 App 与公开完整 DMG 的文件内容、权限及符号链接全树一致，
  arm64 架构及严格代码签名通过。只读测试卷已卸载，没有修改用户已安装的 App 或其数据。
- 再用实际公开包的播放库完成十八次私有原片／基础流渲染：三个时间点、三种解码方式，
  核实实际加载库路径、硬件解码模式与时间戳。九组原片／基础流和九组公开包／候选库输出
  均逐像素字节一致；未运行整个 App，也未读取或更改用户偏好。
- 保留原 Bundle ID、签名公钥、自动更新源、显式偏好、模型与历史；从 v0.2.41 优先使用
  约 1.2 MB 增量包，其他版本或增量条件不满足时保留完整包回退。

| 公开资产 | 字节数 | SHA-256 |
| --- | ---: | --- |
| Apple Silicon DMG | 167977897 | `371e98b790c3b3b1d3a53507b8e983579cf375b72c2e6b177f1c79669069c9c8` |
| From build 52 delta | 1202322 | `59953a3d36c96b1cf2ca89046114ab47d1034f55b460b556ba5c7038c9a04d9a` |
| Signed appcast | 1982 | `6cc537f21067c467b0c9029f82e16615cb01eb9d10bf521c349445b2cac49260` |

本轮发行和公开交付已完成；以上不表示用户 M4 Max 已安装更新，也不替代实体 HDR 显示器验收。
