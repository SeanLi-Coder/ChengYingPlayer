# HDR10+ 精确剪辑与打开面板自动预览

## 范围与原因

基于 `7cecfbd2`，目标版本 `v0.2.64` / build `75`。发布状态以本页最后的记录为准，
本地源码或测试通过不代表已公开发布。

用户授权的约 10.12 秒附件是 HEVC Main10、3600×2338、10 位 limited-range
BT.2020/PQ，270 帧均含 HDR10+ / SMPTE2094-40，而不是 Dolby Vision。
没有静态母版显示元数据，且有稀疏 VFR / open-GOP 时间段。生产 helper 原先直接拒绝
HDR10+；简单移除限制会丢动态信息，因为原版 FFmpeg 9.0.1 的 libx265 不转发该 side data。
个人媒体、截图、完整本地路径和提取内容不纳入仓库或发行资产。

预览的确证缺口是：预创建工具页及打开面板已有默认时间，但只有修改时间或点预览按钮
才会开始播放。旧版真实父视图生命周期负对照在首开自动预览断言失败；不是附件无法解码。

## 实现边界

- 仅用户实际展示工具页、切回剪辑或可见状态下切换素材才请求默认区间预览；等待有效时长。
  隐藏／后台预创建不启动；手动停止、导航、导出、隐藏及更新屏障取消待启动请求。
  重复刷新不重新打开已停止的预览，同 URL 的新媒体 generation 也隔离旧状态。
  暂停中的预览显示暂停，不再写成正在播放。
- FFmpeg 使用锁定源码补丁，显式 `-hdr10plus 1`；每个输入帧必须带支持的动态数据。
  转成完整注册 T.35 SEI 并由 x265 按输入帧复制；另修补无 tone mapping 时丢 saturation 字段。
  默认不启用此选项，不改变其他编码任务。精确补丁、原／后源码、哈希和构建记录随源码包
  与 App 的 `Legal/Media` 分发，保留适用许可证。
- 新 helper 只接收已验证的逐行单层 HEVC Main10、10 位 limited BT.2020/PQ HDR10+。
  保留尺寸、显示矩阵、VFR、静态元数据（如有），视频仍为 CRF 14 高质量有损重新编码，
  普通音频为无损 ALAC，多声道／高位深按既有规则使用 MOV/PCM；不是逐像素无损，
  也不凭空补充母版亮度。明确拒绝未处理的多视频／多音轨／附加流，不静默丢轨。
- 完整 T.35 按实际 PTS 比较，而不是把 FFprobe 重复字段 JSON 变成字典后作不完整比较。
  同时核对实际解码帧、色彩／几何、数量、时间戳和显示方向；丢失、改变、混合或不明确时
  不发布成品。SQLite 索引有界缓存，取消清理本轮临时输出。
- 实际附件的片尾快速 seek 会跳过两张应选中的 B 帧。HDR10+ 通道从头解码后截选，
  不通过放宽校验掩盖漏帧。长原片靠后的选区与完整源包检查可能明显更慢；不能假报 ETA。
- 永久旋转、格式转换及其他未验证动态 HDR 的限制不因此取消。不能把这次测试写成支持
  所有 HDR 格式，也不能把生成测试通过写成所有实体 HDR 屏幕视觉验收。
- 初帧未检出动态信息的静态 HDR 入口，也在编码前检查选段；中途出现动态信息则明确
  拒绝该尚未分类的区间，不沿用旧静态通道悄悄丢弃动态数据。普通 SDR 入口不扩大扫描。

## 验证入口

```bash
python3 -B Tools/ClipPreviewLiveTests/run.py --media /absolute/authorized/video.mp4
python3 -B Tools/ClipPreviewLiveTests/run.py --controller-ref 7cecfbd2 --case opening
python3 -B Tools/VideoToolsTests/run.py
python3 -B Tools/VideoToolsTests/run.py --language en --preview-case waiting --preview-wait-mode observed
python3 -B Tools/VideoToolsTests/run.py --language en --preview-case waiting --preview-wait-mode fixed
python3 -B Tools/HDR10PlusCodecTests/test_codec.py
python3 -B Tools/HDR10PlusCodecTests/test_distribution.py
python3 -B other/verify_media_distribution.py deps
cd Tools/VideoToolsHelper
python3 -m pytest -q
python3 -m ruff check helper.py media.py conversion.py dovi_clip.py hdr10plus_clip.py tests
```

真实媒体只在用户授权后通过参数传入，不能提交到测试资源。生成的 App 使用
`TestAppWorkspace` 隔离、精确注销并正常清理。Ruff 从 helper 目录运行，以保留既有
first-party import 识别。

`--preview-wait-mode fixed` 是预期失败的旧等待方式负对照：在真实 350 ms debounce
回调之前插入可控主线程工作，单次固定 0.45 秒等待会在回调尚未交付时结束。
正常模式以单调时钟设 3 秒上限并观察真实循环、暂停、快照和定时器状态；负向场景
持续监测整个窗口，保留首发时间、停止、隐藏、导航及更新屏障约束。此修订不改生产逻辑。

打包后另运行：

```bash
python3 -B Tools/VideoToolsTests/app_hdr10plus_clip_smoke.py --app /absolute/isolated/ChengYing.app
python3 -B Tools/VideoToolsTests/app_dolby_clip_smoke.py --app /absolute/isolated/ChengYing.app
```

新增 frozen HDR10+ 测试独立解析完整 payload，并覆盖变元数据、复杂可选字段、VFR、
B 帧、静态元数据、音频和重复导出的防覆盖；公开安装验证也要求该检查成功。
发行工作流保留既有签名验证、六种安装／增量故障回退、设置与模型保留及匿名交付门禁。

## 当前状态

本地实现完成，尚未公开发布：

- `v0.2.59` / build `70` 的构建已取消，未公开发布且不移动旧标签。发行测试使用
  独立环境，保留冻结下载器要求的干净 build 环境；修正从仓库根目录运行 HDR10+
  pytest 的模块搜索路径，同等 CI 命令的完整 70 项测试通过。
- `v0.2.60` / build `71` 因旧导航测试替身缺少新的 `automaticPreviewPending`
  字段而未通过编译，构建取消且未发布；本机重现后同步测试边界，并明确验证用户
  导航取消尚未开始的预览，不改生产行为或降低检查要求。
- `v0.2.61` / build `72` 未发布。主线完整功能测试通过，但发行记录归一化漏掉
  临时路径去掉重复斜线后、尚未解析符号链接的拼写；只补精确等价路径替换，保留检查。
  该标签另遇上游 x264 返回 7439 字节错误响应，SHA 检查正确拒绝；同固定 URL 复查
  返回 1040327 字节并匹配原锁，不修改来源哈希或使用异常文件。
- `v0.2.62` / build `73` 未发布。主线旧原生测试在固定 0.45 秒等待后的自动预览断言失败；
  同一检查此前本机与 v0.2.61 两条功能 job 均通过。停止发布后专项验证异步调度边界，
  保留真实预览状态、取消、防抢播与最小 debounce 的断言，不用重试碰运气绕过检查。
  受控主线程阻塞已重现旧等待结束而回调未执行的误判；新等待同条件独立运行三次通过，
  完整三语言套件及当前 opening 三次通过。旧控制器在窗口 active/key、媒体 loaded
  均成立时仍因确实没有自动预览失败，诊断缺失字段安全显示 unavailable。
  另有一次本机 opening 超时在增加细化诊断前发生，未能确定原因，之后未再现；
  不将其无证据归因为窗口焦点，不删除断言或宣称消除所有环境与硬件时序问题。
- `v0.2.63` / build `74` 未发布。标签 `37234937922` 的完整 helper、真实自动预览、
  媒体构建与 HDR10+ 测试、180 秒真实 4K 回归均通过，随后既有 viewport 像素方向断言失败。
  生产 viewport 及其原测试在本轮此前均未改动；未改版强制软件渲染本机 178 项通过。
  固定 100 ms 不保证新画面已交付，受控保存真实前帧读回在 350 ms 延迟下重现旧采样失败。
  Live harness 改为共享 8 秒截止的真实像素和目标属性观察；保留 2 px 精度、全部最终方向／
  尺寸／播放状态／窗口断言、90 秒外部看门狗，未改 production。移除的是 30 个固定等待
  调用成功布尔检查，并非最终画面断言；新正例每次 148 项。
  硬件、强制 Apple Software Renderer、350 ms 前帧读回正例均通过；30 秒阻塞读回与反向
  pan 负例均失败，后者真实 y=161.5 而期望 197.5。原生 viewport 全组两次各 1098 项通过。
  原 CI 日志没有具体坐标和场景，受控竞态不能冒充其唯一原因；新增诊断补齐这项证据缺口。
  主线第一次构建另遭 x264 异常短响应，完整 helper 通过后仅重跑失败构建，不改来源锁。

- 实际附件自动预览 195 项检查、188 张实际渲染帧通过；旧版首开负对照按预期失败。
  三语言原生工具与任务管理回归通过（任务管理每种 132 项）；生产导航入口 310 项通过。
- 完整 helper 366 通过、1 项既有 AV1 fixture 编码器缺失跳过。补上后段动态信息防护后，
  HDR10+ 与基础 media 定向组 146 项通过，其中 HDR10+ 专项 70 项。
- 实际附件 1.417–3.863 秒选出 61 帧；8.417–10.116667 秒选出 56 帧。
  后端与独立校验均通过完整 T.35／PTS／尺寸色彩／音频／完整解码；源 SHA-256 未变。
  冻结 helper 也实际导出片尾，成品 603745 字节，同样独立验证通过。
- 发行 codec 5 项与来源防篡改／路径记录 14 项通过；未补丁 FFmpeg 的负对照明确失败而不跳过。
  补齐路径归一化后完整源码重建、自动生成记录与最终二进制／源码锁复验通过；未手工改记录。
  frozen 生成素材覆盖重复导出、VFR、静态 HDR、复杂多窗口可选字段和稀疏开放 GOP；
  原 Dolby Vision 8.1 / 8.4 的四次 frozen 剪辑仍通过。
- 自动更新策略 19、交付 20、增量资产 14、公开工作区 10 项通过；其余完整 App、
  签名安装与公开交付仍须由既有发布流程完成，不能提前声称成功。

最终提交、流水线及公开资产记录将在验证后补齐。
