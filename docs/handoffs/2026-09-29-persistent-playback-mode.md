# 全局播放模式记忆与明确选择入口

## 基线、范围与状态

- 基线 `e75329bf`，上一正式版 `v0.2.43` / build `54`。
- 分支 `codex/persistent-playback-mode`，目标 `v0.2.44` / build `55`。
- 用户要求找到单文件／列表循环入口，并将最后一次选择作为所有视频的全局默认，
  直到再次修改。没有要求强行将每个用户初始模式改为单文件循环。
- 本节记录实现与本地验证；正式发布结果见末尾，不把提交或标签当作已发布。

## 实现

- 右上角文件列表中的「文件／播放列表」两种视图均显示「播放模式」选择框，
  提供顺序播放（不循环）、单文件循环、列表循环。队列底部循环按钮改为带当前勾选的菜单；
  顶部「播放」菜单增加明确的关闭循环入口，保留原单文件／列表切换动作。
- 沿用 `autoRepeat` 与 `defaultRepeatMode`，不制造另一套冲突偏好或迁移旧用户配置。
  显式界面／标准快捷键选择保存并同步已初始化窗口；新 core、手动打开及 `on_preloaded`
  恢复最新选择，包含自动下一项、重用窗口和已明确关闭循环的情况。
- 注册默认值不冒充已保存选择。尚未保存过循环设置时保留已有 mpv 临时行为；
  一旦明确选择，之后文件载入使用该全局模式。普通 mpv 属性通知只刷新界面，
  不将文件级配置、watch-later 或临时 IPC 状态写回全局默认。
  显式 Foundation 启动参数保留原有优先级，仅在当前运行生效，不写入持久偏好。
- 单文件与列表重复的两个底层开关互斥。修改模式不跳转、不恢复播放、不修改 A/B 标记。
  是否自动进入下一项仍遵守已有自动播放设置；A/B 区间仍在换文件时清除，不跨文件继承。
- 真实引擎负向测试复现：起始为单文件循环，文件携带旧 file-local 循环选项，
  中途切为列表循环后两项播完仍停止。原因是 mpv 卸载文件时恢复旧选项，
  单靠下次 `on_preloaded` 来不及影响列表末尾的下一项决策。
  在原有载入恢复之外增加 `on_after_end_file` 恢复，位于旧选项复原之后、下一项决策之前；
  不修改底层播放库，也不把 mpv 的临时状态持久化。
- 识别已有 `loop` / `loop-file` / `loop-playlist` 的标准开关快捷键；
  自定义有限次数及复合命令继续交给 mpv，不声称这些任意脚本都属于三种全局模式。
- 三语控件、VoiceOver 当前值与说明一致；偏好页面的旧「手动打开时」文案改为全局循环。
  没有修改下载器、HDR 默认、媒体文件、个人浏览器或账户数据。

## 本地验证

- `bash Tools/PlaybackModeTests/run.sh`：126 项生产方法／偏好检查，
  file、playlist、off 各自实际跨进程写入／恢复通过。只使用随机独立测试 Bundle ID；
  带 Address Sanitizer，Intel macOS 10.15 类型检查通过。
- `bash Tools/PlaybackModeUITests/run.sh`：英文、简体、繁体各 51 项，合计 153。
  编译实际控件与菜单方法，在 240 pt 最窄侧栏检查布局；隔离 AppKit fixture 截图已视觉检查。
  不是用户真实窗口截图或实体快捷键验收。
- `bash Tools/SilentVideoOpenTests/run.sh`：215 项，保留视频静音载入。
- `bash Tools/PlaybackModeLiveTests/run.sh`：58 项，直接编译生产模式读写和载入／卸载 hook，
  链接真实 libmpv 并播放临时合成素材，验证单文件两次回绕、列表往返、队列清除、停止重开、
  暂停位置与 A/B 保留，以及自动下一项设置。较早 hook 注入陈旧 file-local 循环选项，
  生产 `on_preloaded` 在播放前恢复模式，覆盖自动换片与回绕。
  额外实测中途单文件→列表、列表→关闭，在文件卸载恢复旧选项后仍按最新模式回绕或停止；
  此边界不访问 UserDefaults。双 hook 的关闭／释放时仍继续一次且不写入失效 mpv 已独立检查。
- 原有 playlist playback 3,854 项与真实 libmpv 36 项；playback lifecycle 76 项、
  chrome lifecycle 157 项、simplification 144 项、preference search 11 项通过。
- 原有 playlist presentation/filter/folder browser 套件通过；工具播放／打点 618 项、
  rotation coordinator 77 项、task manager 23 项通过；HDR preference 42 项、color state 149 项通过。
- 原生更新 143 项；release policy 19 项、delivery、delta assets 14 项、实际签名 23 项通过。
  实际增量升级 fixture 已把 `autoRepeat` / `defaultRepeatMode` 加入保留数据，
  下载增量、安装、一次重启后原值与类型保持，模型、配置、书签和历史也保持。

## 发布状态

最终独立 review 与本地回归通过；等待完整 CI 和公开发行物验收。
不得覆盖现有 v0.2.43 附件或标签。
