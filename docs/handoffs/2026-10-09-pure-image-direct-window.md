# 纯净看图：直接移动图片窗口与等比最大化

基线：`fb90a2430dc61a8e69b2ca715152d8a365799009`，正式版本 `v0.2.74` / build `85`。
分支：`codex/pure-image-direct-window`。本轮唯一发布者：Codex。
正式版本：`v0.2.75` / build `86`，北京时间 **2026-10-09 17:40:15** 已发布。

## 用户要求与现场核实

用户要求纯净模式下直接拖图片移动整个窗口，而不是只在较大黑色画布内移动图片；
支持最大化／恢复、四边四角调整窗口大小。用户明确选择 **保持图片比例**，不需要拉伸变形。
本机正式安装的 `Info.plist` 仍为 `v0.2.72` / build `83`，尚未使用已发布的
v0.2.74 贴图窗口修补；这不替代本轮新增交互。未覆盖正式安装或更改用户设置。

## 实现约定

- 纯净模式默认拖动移动整个窗口；Option＋拖动保留局部平移，普通编辑模式保持原行为。
- 双击及右键菜单提供最大适合当前屏幕／恢复，原生全屏作为独立功能保留。
- 保持图片比例、窗口原生四边四角缩放以及完整图像，不以裁剪或变形隐藏留边。
- 窗口模式下滚轮、捏合、加减键调整贴图窗口；Option＋滚轮／捏合与原始像素入口
  保留局部检查。原生全屏无法调整窗口大小时，默认手势仍执行原来的局部缩放。
- 进入纯净模式默认适应图片；普通模式缩放／平移状态只在同一图片源返回时恢复。
- 保留全屏过渡、跨屏、动画、极端长宽比可操作窗口和更新活动屏障。
- 验证只使用合成素材和临时偏好，不上传用户图片、路径或原始元数据。

原生窗口移动使用 AppKit 的 `performDrag(with:)`。Apple 明确说明该调用立即返回，且
可能不再投递 mouse-up，因此不能仅用函数返回或 `mouseUp` 作为拖动结束信号；须正确
清理拖动期间状态，避免跨屏自动适配与 WindowServer 争抢窗口位置。
参考：[Apple API 文档](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:))。

## 验证记录

递增候选版本后，更新策略、交付、增量资产测试合计 53 项和 95 个子测试通过。
真实 Sparkle 签名及增量生成回归合计 33 项和 69 个子测试通过，使用临时密钥与受管
`TestAppWorkspace`；两个 pytest 警告为辅助类有构造函数而不参与测试发现，不是跳过用例。
图片编辑 160 项及 Intel typecheck、更新活动屏障 49 项与真实 helper 退出 24 项通过。
图片后端 201 项及 Intel typecheck、原生 updater 143 项检查通过；updater 运行在
受管独占 `.noindex` 工作区，精确注册清理通过，未替换正式安装或修改用户偏好。
`bash Tools/ImageSlideshowTests/run.sh` 98 项、`bash Tools/ImageRoutingTests/run.sh` 56 项通过。
生产交互修改后，`bash Tools/ImageCropTests/run.sh` 141 项及 Intel typecheck 通过，
普通编辑模式的裁剪边角、锁定、Option 平移和原双击行为保持正常。

最终 `IMAGE_VIEWER_TEST_FULLSCREEN=1 bash Tools/ImageViewerUITests/run.sh` 并设置独占
`IMAGE_PURE_VIEW_SCREENSHOT_DIR`：原生 UI 217 项（含 4 项合成窗口截图），真实 ImageIO
249 项（含 1 项截图），macOS 10.15 Intel typecheck 均通过。未启用截图时相应为
213／248 项；不能把额外截图计数说成新增功能用例。日志
`build/pure-image-direct-window-final.log`。幻灯片 UI 131 项通过，日志
`build/pure-image-direct-window-slideshow.log`。

新增检查包括完整的第一次按下／抬起／第二次按下双击序列、迟到拖动 timer 不撤销最大化、
Option 局部平移、窗口加减缩放、返回普通视图、比例不同的新页面、原生缩放结束后的状态、
实际全屏缩放以及既有极端图保护。1080×1066 合成图的最大化实际画布为 1239×1223 point，
图像矩形为 1239×1222.9389 point；严格双轴贴边及边缘像素检查通过，窗口截图未见大黑框或工具栏。
窗口尺寸／位置改为整 point，消除了分数边缘被 AppKit 双端取整时多出的 1 point，
未放宽原有几何断言，未拉伸或裁剪图片。快速双击的前次拖动跟踪也在第二次按下明确终止，
不再依赖 100 ms timer 恰好观察到两次按压之间的释放。独立最终复审无发布阻断。

本机没有事件注入权限：`window.sendEvent` 能验证原生 `performDrag` 接收到原始事件且
不误平移图片，但合成后续事件不能驱动 WindowServer 移动窗口。双击最大化／恢复已通过
实际窗口事件与 frame 检查；**物理鼠标拖窗、四边四角实拖及真实跨显示器拖动仍需人工确认**。
没有为测试另造与生产不同的拖拽实现、申请辅助功能权限或把合成事件验收写成物理操作成功。

## 正式发布与公开交付复核

提交 `0beb25df34b9a0c6a6b81a0ee1f3e258a3d97103` 对应不可变标签 `v0.2.75`。
标签流水线 `37907880848`、主线 `37907880889`、拼写 `37907880847` 全部通过。
标签媒体检查用时 20m48s，完整 Apple Silicon 构建与回归 44m29s；实际升级安装／重启、
4K 关闭／重开、静音打开、循环、旋转、打包 Dolby Vision／HDR10+ 剪辑均通过。
发布 job `113761217719` 成功，正式 Release 包含八个资产，非 draft、非 prerelease。
发布地址：[v0.2.75](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.75)。

本机通过仓库 `other/verify_public_release.py` 以已独立验证的 v0.2.74 / build 85 报告
`build/ReleaseVerification.noindex/release-v0.2.74-public.3n2plauu` 与其可信 plist 为基线复核。
只在验证进程内设 `NO_PROXY=*` 并启用系统 CA 的 truststore；未关闭 TLS、未改系统代理。
结果位于 `build/ReleaseVerification.noindex/release-v0.2.75-public.8ywp3kft/verification.json`，
退出 0：匿名 latest、客户端固定 feed、完整包与每个增量的字节／SHA、旧公钥验签、
增量重建全树及代码签名一致、冻结 helper 身份与 HDR 剪辑自检全部通过。
`volumes_detached` 与 `test_apps_cleaned` 均为 true；受管测试 App 已精确注销／清理，
可信 plist 与报告独立保留，不依赖测试 App、不覆盖正式安装、不接触用户原图与偏好。
下载器自检仅为合成离线检查，不代表本轮测试了真实账号或站点。

- 完整 DMG：168,991,455 字节；SHA-256
  `c8f2b84d9888cfea1f1ee2e8b975e1e5549ae517ea45c18f57c7638297b432b4`。
- 从 build 85 的增量：1,223,898 字节；SHA-256
  `019824601fcb7a3976008292627b0c658870d02702c0632545b51c8d5154de7c`。

剩余人工验收为上述 WindowServer 物理拖动／边角／跨屏的实际操作验证；没有因此跳过其他发行检查。
