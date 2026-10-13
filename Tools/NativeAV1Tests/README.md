# Native AV1 VideoToolbox / dav1d 回退验收

本组编译真实 `CYNMediaDecoder.m`，读取真实合成 AV1 文件并核对解码出的 YUV、PCM、PTS、seek 和 EOF。
它不是完整播放器窗口或屏幕像素测试，不改变默认播放后端，不发布应用，不读取用户媒体。
采用相同 FFmpeg 库不代表与 Movist Pro 使用相同播放内核。

## 库和补丁边界

- 播放库仍为锁定的 FFmpeg **7.1.5**。导出/剪辑 helper 的 FFmpeg 9 版本和补丁不变。
- 原始 OSS backport 来源为 FFmpeg `f9c5c5358cfef3847674c6f3b3ded9611ebc5647`，补丁 SHA 为
  `bb36ff97372dd9d28e7b2124aea772cbeb2d97596b895c21b06740c2f450bb9e`；不篡改其原始内容。
- 单独本地补丁 `ffmpeg-7.1.5-av1-videotoolbox-append-error.patch` 的 SHA 为
  `478b60e792397f4c5aaf194774639ed1253c8446b01eeb1fca08a51b83aec28b`：
  AV1 OBU 追加失败时直接返回；`ff_get_format` 仅对 AV1 的 `ENOMEM` / `AVERROR_EXIT` 停止再次选择格式。
  H.264 等其他 codec 的原有格式回退规则不变。
- 新增源文件必须在原始 FFmpeg archive 中完全不存在；空文件和符号链接也不能冒充“未存在”。
  patch 原文、原始文件、修改后文件、新增文件清单和实际 dylib/header 都有独立 SHA 校验。
- source package 从 Git archive 包含新补丁及四份锁，并保留 `playback-build-record/ffmpeg-av1-backport`。
  `third_party_sources.sh` 仅追加 manifest 记录，没有改 helper 构建配置。

## 生产行为

AV1 明确选择带 VideoToolbox HW config 的 FFmpeg `av1` decoder。无该配置时直接选 `libdav1d`；
实际设备不可用或确认发生 VT 格式初始化拒绝时，只在第一张视频图像输出之前切换软件。
压缩视频 replay 最多保留 **64 包、8 MiB**（计入 backing buffer、side data、结构和 padding），
超过限制先切软件；单个超大当前包不会再复制到缓存。音频、demux 和同一打开的 FD 不回卷。
当前失败包只回放一次，原有音频 PCM、PTS、duration 和样本数保持不变。

内存分配失败、取消、损坏输入及无法证明的初始化错误不按“硬件不可用”重试。
已找到 codec 但 `avcodec_alloc_context3` 返回 NULL 明确归类 `ResourceLimit`，不误标为
`Unsupported` 触发 App 的初始 MPV 兼容回退；真正找不到 codec 仍保留 `Unsupported`。
FFmpeg 上层有时将底层资源错误泛化成解码错误，因此这里承诺 **fail-closed、不软件重试**，
不宣称最终 NSError 能精确区分所有底层资源原因。
首张视频输出后的硬解错误仍明确失败；本轮没有实现无缝中途切换。
同 FD 的 seek / 原点重建保留本文件已经选择的软件路径，新 open（包括同 URL）重新探测。

`hardwareDecoded` 的 AV1 证据是：实际产出 VT frame、确为所选 native AV1 decoder，且锁定 FFmpeg
在创建该 AV1 session 时使用 `RequireHardwareAcceleratedVideoDecoder`。
单独 `CVPixelBuffer`、`VTIsHardwareDecodeSupported` 或配置存在都不作为硬解成功证据。
HEVC 仍保留原来的“VT 输出不等于已确认硬件”口径。

## 运行

在仓库根目录执行。默认 `--deps deps`；新补丁必须先构建，旧库会被验证器拒绝。
可以在独立路径构建而不覆盖现有 `deps`：

```bash
PLAYBACK_PREFIX="$(mktemp -d "$PWD/build/native-av1-playback.XXXXXX")"
bash other/build_playback_libraries.sh "$PLAYBACK_PREFIX"
SOURCE_CACHE_DIR="$PWD/deps/sources" python3 other/verify_playback_distribution.py "$PLAYBACK_PREFIX"

python3 -B -m unittest discover -s Tools/NativeAV1Tests -v
python3 -B -m unittest discover -s Tools/PlaybackDistributionTests -v
python3 -B Tools/NativeAV1Tests/run.py --deps "$PLAYBACK_PREFIX"
python3 -B Tools/NativeAV1Tests/run.py --deps "$PLAYBACK_PREFIX" --sanitizer address
python3 -B Tools/NativeAV1Tests/run.py --deps "$PLAYBACK_PREFIX" --sanitizer thread
python3 -B Tools/NativeAV1Tests/run_matrix.py --deps "$PLAYBACK_PREFIX"

NATIVE_DECODER_DEPS="$PLAYBACK_PREFIX" bash Tools/NativeDecoderTests/run.sh
NATIVE_DECODER_DEPS="$PLAYBACK_PREFIX" NATIVE_DECODER_SANITIZER=address bash Tools/NativeDecoderTests/run.sh
NATIVE_DECODER_DEPS="$PLAYBACK_PREFIX" NATIVE_DECODER_SANITIZER=thread bash Tools/NativeDecoderTests/run.sh
```

构建要求与生产 build 脚本相同，包括可用的 Meson/Ninja/CMake。`FFMPEG_BIN` 可指定用于生成合成
容器及独立参考数据的 CLI；它不是被测播放 dylib。默认 `/opt/homebrew/bin/ffmpeg`，
该独立参考 CLI 必须包含 **libdav1d video decoder**，runner 在生成素材前检查能力并保存实际 listing。
生产 bundled helper FFmpeg 9 未启用 libdav1d，不能拿它生成本专项参考；CI 可仅在此测试步骤使用
`FFMPEG_BIN="$(brew --prefix ffmpeg)/bin/ffmpeg"`，不修改生产 helper 的配置。
fixture 中的 8/10-bit IVF 为 192×108、12 fps、24 帧合成 testsrc2；编码器为 FFmpeg 9.0.2 / SVT-AV1 4.2.0，
原始 IVF SHA 固定在 `run.py`，不需要用户或网络视频。额外 96 帧素材用于验证压缩包数量上限。

ASan / TSan 编译当前 CYN 和测试代码；预先构建的第三方 dylib 不会因此被重新 sanitizer instrument。
`source.sha256`、`generated.sha256`、`hash-validation.json`、`provenance.json` 和日志保存在本轮独占的
`build/native-av1-tests.*`。任何输入、生成参考数据或实际库/header 在测试中变化都会令结果失败。
资源函数专项另存 `build/native-av1-resource-boundary.*`，真实函数由已验证并实际应用补丁的源码机械抽取，
只替换分配/硬件初始化外部边界；不伪造硬件帧。

## 负对照和 M4 验收

以下两个命令必须返回非零：分别移除初始化软件回退，以及丢掉 replay 首包。
未知负控名称由 argparse 拒绝，不会误跑成普通通过。
CI 应使用 `run_matrix.py`，它先跑真实 normal，再跑两个负控；要求具体 packet/frame 失败标签、
完整执行摘要、准确退出码、未改变的源码/库/生成物和同源身份。编译失败、超时、sanitizer 错误或无关失败
不能当作负控通过。原 `run.py --negative-control` 仍返回 1，不会默认把失败转换为成功。

```bash
python3 -B Tools/NativeAV1Tests/run.py --deps "$PLAYBACK_PREFIX" --negative-control disable-fallback
python3 -B Tools/NativeAV1Tests/run.py --deps "$PLAYBACK_PREFIX" --negative-control drop-current
```

资源函数单测自带两个单变量负控：撤销 AV1 `ff_get_format` 资源门禁必须触发 CYN 误回退断言；
撤销 OBU 追加错误检查必须触发“截断内容不可送给 VT”断言。普通 unavailable 和 H.264 是正向对照。

在目标 M4 上，使用已通过完整分发验证的新库执行：

```bash
python3 -B Tools/NativeAV1Tests/run.py --deps "$PLAYBACK_PREFIX" --require-hardware
```

strict 模式不接受软件回退。8/10-bit 的首次解码、indexed seek 后尾段、同 FD 原点 restart、同 URL 新 open
每一次真实 drain 都要求至少一帧，且 `hardware == videotoolbox == 全部实际帧数`，software open / fallback 必须为零。
这只验收小型 8/10-bit AV1 的解码路径；M4 的完整窗口、4K 长时播放、能耗、实体 HDR 屏与真实声卡仍需独立验收。

## 2026-10-13 本机证据

机器为 **Apple M2 Pro / macOS 26.7.1**。CYN SHA：
`e3bcc18ecde84e48cf5556308eac7fc9802d6e5818ceecabe5b85e738b8958b9`。
生产 build 脚本完整重建至 `build/native-av1-playback.7FMHum`，没有覆盖原 `deps`；完整分发校验通过。
新 `libavcodec.61.dylib` SHA 为 `a183c8200217cf86a17817d6049efeb3502102bb02756224994d5ed5dec62dcc`，
9 库清单 SHA 为 `23955a8c9134525cea8cccb24e50ac3fe10b7a1258accdb0727d81904d016725`。

| 验证 | 结果 | 独立证据目录（均在 `build/`） |
| --- | --- | --- |
| AV1 normal | 7,486 / 0 | `native-av1-tests.lnilr6qr` |
| AV1 ASan | 7,486 / 0 | `native-av1-tests.0l_3_wwm` |
| AV1 TSan | 7,486 / 0 | `native-av1-tests.a_615p9e` |
| 无回退负控 | 3,490 / 110，预期失败 | `native-av1-tests.r30crjr0` |
| 丢首包负控 | 2,708 / 98，预期失败 | `native-av1-tests.reazby46` |
| 严格批跑校验 | normal + 两负控准确通过分类；源/库身份一致 | `native-av1-matrix.g1lz9q32` |
| M2 strict hardware | 1,738 / 18，预期拒绝软件路径，不是 M4 验收 | `native-av1-tests.m90_jooj` |
| 原 Decoder normal（PATH 无 rg） | 9,265 + 26,210 断言；Swift 308 samples | `native-decoder-tests.etmyFc` |
| 原 Decoder ASan | 同上，全通过 | `native-decoder-tests.tzADXh` |
| 原 Decoder TSan | 同上，全通过 | `native-decoder-tests.EsIqQc` |
| 真实函数资源边界 | 正向 34 / 0；两个负控分别 34 / 6、34 / 8，预期失败 | `native-av1-resource-boundary.4k1t6ehc` |
| 缺失参考 decoder 对照 | bundled helper 无 libdav1d，在生成素材前明确失败 | `native-av1-tests.zseqk61_` |

补丁/manifest/真实函数共 9 个 Python 测试，另有批跑分类器及参考 CLI 11 个反例/正例单测，合计 20 个通过；分发验证 38 个测试通过。
原 Decoder runner 默认依赖路径不变，可指定独立路径；用系统 `find -print0` 保存 SDK 清单，
本轮实际记录并验证 145 headers + 5 直接链接库，缺少清单不会静默通过。
M2 真实初次解码两种位深均为 `native_opens=1 software_opens=1 fallback=1 frames=24 vt=0 hardware=0`；
这证明本机不支持的 AV1 VT 初始化能回退并完整软件播放，不是 AV1 硬解验收。
另有无 VT config 的受控边界，明确检查 `native_opens=0 software_opens=1 fallback=0`，
实际 YUV / PCM 仍与独立 dav1d 参考相等；此边界不冒称已运行历史旧 dylib。

保留失败历史：`native-av1-tests.a4188lrz` 首轮 116 断言 / 90 失败，定位为 audio open 错误触发 AV1
software fallback，已用 `video &&` 门禁修正，未删减失败断言。后续 `gm5ia1lw` / `pqjwxh_3` 只使用
旧 OSS-only 候选库，不能当作新资源补丁库的最终证据。首次重建 `build.log` 因找不到 Meson 失败，
随后给该命令指定已有工具目录，`build-attempt2.log` 完整构建成功；没有修改系统全局工具链。
最后的 context 分配复核用真实 C 调用边界复现旧分类错误：`native-av1-tests.1ioa23m8` 为
7,486 / 4（video/audio × 8/10-bit），四项均是 `ResourceLimit` 被误标为 `Unsupported`。
拆分“codec 缺失”和“context 分配失败”后，上表三模式全部通过；未改动 FFmpeg 库或放宽断言。

本组不声称完整 App、M4 硬解、默认后端切换或正式发布已完成。
