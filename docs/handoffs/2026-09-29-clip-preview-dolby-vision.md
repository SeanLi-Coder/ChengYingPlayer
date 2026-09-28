# 剪辑预览与 Dolby Vision 剪辑修复

## 范围与状态

- 基线：`971535ca`（v0.2.44 发布核验记录）；分支 `codex/clip-preview-hdr-fix`。
- v0.2.45 / build 56 已于北京时间 2026-09-29 03:01:54 正式发布，标签提交 `2ea960369b7ecaacdb6cc799d7c7792b89eb623c`。
  本文初次提交时尚未发布；以下正式交付记录在公开安装包验证后追加。
- 用户报告工具侧栏找不到预览，剪辑出现 `Dynamic HDR metadata cannot be preserved safely`。
- 提供的 MP4 附件经核实是 H.264 / BT.709 SDR，与截图中的 MOV 不同，不能拿它证明原始 HDR 故障已复现。
  已请求原始 MOV，未收到前不宣称该特定原片实测通过。真实附件只读、本地处理，不进入源码或发行包。

## 实现

### 预览入口

- 预览、区间状态、确认、取消入口固定在工具面板底部。较长错误详情和导出进度放进可滚动区域。
- 有效时间输入经过 350 ms 合并后使用现有主播放器自动预览，不额外创建解码器或转码预览文件。
- 状态明确显示预览所在位置和当前范围；输入无效时停止旧预览并解释原因。
- 临时预览会保存并恢复原来的播放状态及键盘 A/B 循环；显式清除 A/B 仍是独立动作。
- 相关实现：`iina/VideoTools/VideoToolsViewController.swift`、Models / TaskManager 与三语字符串。

### 动态 HDR 剪辑

- 新增 `Tools/VideoToolsHelper/dovi_clip.py`，只启用经过校验的单层 HEVC Dolby Vision 8.1 / 8.4。
- 沿用 CRF 14 高质量重新编码与无损音频编码，不承诺视频逐像素无损。非关键帧起止不扩大到整个 GOP。
- FFmpeg / libx265 接收逐帧动态元数据，设置 Dolby Vision 所需 VBV 参数，输出带正确配置记录的 MP4。
- 关闭自动旋转，保留原始显示矩阵与编码尺寸，避免旋转画面而未同步变换动态元数据几何信息。
- 发布前用 FFmpeg 的 `dovi_rpu=compression=none` 规范化完整 RPU 并逐帧比较 SHA-256、时间戳、数量；
  另外检查实际解码帧与数据包一致。不是只检查容器标签或 FFprobe 能展示的部分字段。
- 同时核对每个所选帧的静态 Mastering / ContentLight 参数；区间内变化或缺失会安全拒绝，避免 HDR10 基础层参数被固定成错误值。
- 排序使用私有临时 SQLite 索引限制内存；取消／失败清理本任务临时产物。源文件及已有导出不被覆盖。
- Dolby Vision 7 双层、其他动态 HDR、隔行、元数据缺失或核验不一致、不能安全封装的音频继续明确拒绝。
  8.1 还要求可验证的静态 HDR 元数据；不把未知格式悄悄降成静态 HDR / SDR。
- HDR 预检查和验证显示具体中文阶段；验证时清空编码阶段的 ETA，完成后才显示 100% 和剩余 0，避免长片核验被误报为马上完成。
- 只扩展剪辑；旋转、格式转换和烧录字幕的动态 HDR 限制未改变。没有新增用户下载依赖。

## 本地验证

- `bash Tools/VideoToolsTests/run.sh`：控件 762 × 3 语言、旋转协调 77、任务管理 102 × 3 语言通过。
  覆盖宽 320/360、高 240/300/350/400/600 的控件可见性、长错误、滚动可达性与 A/B 恢复。
- 隔离 AppKit 截图目视检查通过；它不代替真实 M4 Max / HDR 显示器验证。
- 新增 `Tools/VideoToolsTests/app_dolby_clip_smoke.py`：对真正冻结的 helper 和发行 FFmpeg 执行四次剪辑，
  覆盖 8.1 / 8.4、VFR、非关键帧起止、完整 RPU、音频、源文件不变和重名输出，通过。
  此测试已加入完整 App 构建的必过步骤；没有用系统 Python 替代被测 helper。
- 既有冻结格式转换 smoke 五次通过；用户提供的 SDR MP4 在冻结 helper 中精确剪辑并完整解码通过，原片摘要不变。
- 更新回归：发布策略 19、交付 20、增量资产 14、原生更新 143、签名更新 23 项通过。
  真实 `delta-upgrade` 完成安装／重启并保留设置、书签、历史和模型，实际只请求增量载荷。
- 新增 HDR 测试使用合成色块与自生成动态元数据；生成方法及来源随 fixture 提交，未包含私人影片。
- 独立评审用真实 HEVC 静态 SEI 变化构造负例，确认被拒绝且无成品残留，已纳入 `test_dovi_static_metadata.py`。
  实际取消阻塞中的校验子进程也已独立验证，无进程残留。
- 发行 FFmpeg 9.0.1 下完整 helper 测试最终为 **298 passed、1 skipped**（原有 AV1 测试编码器不可用），Ruff 全部通过。
  对应 HDR 专项、真实静态 SEI 负例和 ETA 阶段回归均执行；正式发布及公开交付结果见下节。

## 正式发布与公开交付

- [正式发布页](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.45)：
  发布时间 `2026-09-28T19:01:54Z`，稳定版本，八个发行资产齐全。
- 主线 CI `36462127456` 与正式标签 CI `36462135491` 第二次执行均成功；拼写检查 `36462127407` 成功。
  包括完整 App 的实际安装／重启、循环边界、格式转换、四次精确 Dolby Vision 剪辑、快速旋转、
  真实 4K 渲染、HDR / SDR 与增量更新检查，没有跳过或降低失败断言。
- 标签首次构建收到不符合锁定摘要的 x264 源码下载并安全停止。保留原版本、URL、SHA-256，原标签重试后恢复，未移动标签。
- 主线首次在既有软件渲染纵向画面平移的像素断言失败。本次没有修改该生产代码或测试；
  本机原测试五次（一次硬件、四次软件，每次 178 项）及两条 CI 重试通过。
  评审发现属性确认与画面呈现之间可能存在采样时序差，但日志不足以确认实际根因；不能写成已修复或放宽断言。
- 匿名请求核实 GitHub latest、实际客户端 feed 与不可变标签 feed 相同；完整 DMG、增量包及各校验和
  的大小与 SHA-256 均匹配公开资产。旧版 v0.2.44 公钥验证 feed、完整包和补丁均通过，更新身份未改变。
- 对公开 v0.2.44 实际应用公开补丁，结果与完整 v0.2.45 App 的全部文件、权限、符号链接一致；严格代码签名通过。
  对还原的公开 App 运行冻结下载工具离线 Cookie 自检，以及四次实际 Dolby Vision 剪辑 smoke，全部通过。
  剪辑检查完整 RPU、精确帧区间、音频和原文件摘要；测试运行没有改变 App 文件树。
- 完整包：`168678199` 字节，SHA-256：
  `34f1f4718be27bc16649ff2b67ee1b4a2db168712033899e24e261b4c78f9553`。
- 从 build 55 的增量包：`1944618` 字节，约 1.94 MB，SHA-256：
  `fed3f4d89562b7128ccbc9934323a8db76752b148abbebfa6fea80bc2af1f1ce`。
- 公开 feed SHA-256：`284326ae217d50798c7f5b3fd4ddf37cc5b5fcfe19e04df11e33bb5a6e596fb4`。
- 收尾限制：旧测试卷已卸载；新测试卷的全部验证已完成，但正常卸载被本机安全扫描程序拒绝。
  保留该只读临时测试卷，没有停用安全服务或强制卸载。验证脚本因此返回清理失败，而非安装包校验失败；
  不将其记录成整个脚本零退出。未覆盖本机安装、真实媒体、模型或偏好。

## 运行方式

```bash
cd Tools/VideoToolsHelper
PATH="../../deps/executable:$PATH" ../../build/player-v29-tests.nD75s9/bin/python -B -m pytest -q
../../build/player-v29-tests.nD75s9/bin/python -m ruff check helper.py media.py conversion.py dovi_clip.py tests
```

上面的隔离 Python 路径仅是开发机已有环境示例；其他机器按 helper 文档创建自己的测试环境。
正式包烟测从仓库根目录运行：

```bash
python3 -B Tools/VideoToolsTests/app_dolby_clip_smoke.py --app /path/to/ChengYing.app
bash Tools/VideoToolsTests/run.sh
```

## 验证限制

- 尚未取得截图中的原始 MOV，不能确认其具体 Dolby Vision Profile 或是否包含其他动态 HDR。
- 本轮不测试真实账号下载，不改变下载器、模型文件、用户设置或更新信任身份。
- 重编码及完整动态元数据检查需要时间；不为长视频宣称固定 ETA 或瞬时完成。
- 正式发布已核实旧公钥、完整 DMG、增量还原全树一致及匿名公开更新地址；后续版本仍须逐次执行，不能以本地测试代替。
