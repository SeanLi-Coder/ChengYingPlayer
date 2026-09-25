# HDR preference regression

运行：

```sh
bash Tools/HDRPreferenceTests/run.sh
```

需要 macOS 和 Xcode Command Line Tools，不需要完整 Xcode、媒体文件、libmpv 或 HDR 显示器。
脚本同时执行 `x86_64-apple-macos10.15` 类型检查以及本机架构的编译、运行。
可用 `HDR_PREFERENCE_SOURCE_ROOT` 指向另一份源码进行对照验证；默认检查当前仓库。

验证范围：

- 从实际 `Preference.swift` 读取现有 key 和默认值，要求默认关闭 HDR。
- 检查 `PlaybackInfo` 初始状态，以及 AppDelegate、PlayerCore、QuickSetting 和 VideoView 的现有连接。
- 解析偏好设置的实际 XIB，要求 HDR 复选框初始未勾选，同时保留已有 `values.enableHdrSupport` 绑定和手动勾选能力。
- 在随机 UUID 命名的 `UserDefaults` suite 中验证：未设置时关闭；旧隐式默认开启升级后变为关闭；明确保存的开启／关闭选择不被覆盖；删除保存值后回到默认关闭。
- 启动独立子进程，验证上述状态在重新读取偏好时仍成立。

测试不读取或修改播放器真实偏好；只清理本次创建的 UUID suite 和临时编译目录。
快速设置的手动 HDR 开关保留其现有“当前播放器”行为，测试不将它误称为自动保存全局偏好。

这是**生产源码连接检查 + 原生 UserDefaults 行为回归**，不是完整 App GUI 测试，
也不是 HDR 显示器、视频解码、色彩准确性或 EDR 亮度的硬件验收。
