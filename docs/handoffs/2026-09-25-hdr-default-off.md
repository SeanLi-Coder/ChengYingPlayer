# HDR 默认关闭：联合开发交接

## 范围和基线

- 用户要求：默认不要开启 HDR，仍保留手动开启能力。
- 基线：`662d5a0e7939d9233c5f06aeb0e78f084fa25f97`。
- 功能分支：`codex/hdr-default-off`；独立提交供另一台机器整合。
- 本改动不修改快手实现、媒体文件、HDR 元数据、导出策略或自动更新身份。

## 实现

- `iina/Preference.swift`：`enableHdrSupport` 注册默认值改为 `false`。
- `iina/PlaybackInfo.swift`：`hdrEnabled` 初始化为 `false`。
- `iina/Base.lproj/PrefCodecViewController.xib`：HDR 复选框初始不勾选，保留原偏好绑定。
- `Tools/HDRPreferenceTests/`：隔离偏好域的原生回归及生产源码连接检查。
- `.github/workflows/ci.yml`：接入 HDR 回归；`README.md`：说明默认值及升级行为。

新安装，以及旧版没有明确保存 HDR 偏好的用户，均采用默认关闭。
已有明确保存的开启／关闭选择保持不变，不新增强制覆盖用户选择的迁移。
设置中的 HDR 复选框仍保存全局偏好；播放快捷设置中的 HDR 开关仍只影响当前播放器。
不要将此改动扩展为删除 HDR 支持、强制修改源视频或关闭所有色彩管理。

## 本机验证

| 命令 | 结果 |
| --- | --- |
| `bash Tools/HDRPreferenceTests/run.sh` | 42 项通过；Intel macOS 10.15 类型检查通过 |
| `bash Tools/SimplificationTests/run.sh` | 144 项通过 |
| `bash Tools/PreferenceSearchTests/run.sh` | 11 项通过 |
| `bash Tools/ICCProfileTests/run.sh` | 6,164 项检查、12 次真实离屏渲染通过 |
| `python -B Tools/SparkleUpdateTests/test_release_policy.py` | 19 项通过 |
| `python -B Tools/SparkleUpdateTests/test_release_delivery.py` | 15 项通过 |
| `git diff --check` | 通过 |

Python 命令使用已有隔离测试环境。更新测试是离线回归，不是实际发布或安装结果。
HDR 测试仅使用随机 UUID 偏好域，不读取或更改真实 App 偏好。
ICC 离屏渲染不是 HDR 显示器验收；尚未进行完整 App、真实 HDR 屏幕和 M4 Max 画面验收。

## 当前发布阻碍与交接

截至本次核实，基线 `662d5a0e` 的 CI 在本 HDR 修改前已有两个失败：

1. [构建 CI](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36134145460)：
   Apple Silicon App 构建成功，但下载 helper 测试 1 项失败、472 项通过、62 个子测试通过。
   `test_kuaishou.py` 的 Cookie 异常分类测试没有隔离 Chrome 用户目录，CI 返回
   `chrome_data_directory_missing`，断言却要求 `cookie_access_unknown`。
   应固定合成的临时浏览器目录，不应改生产诊断来迎合开发机环境。
2. [拼写 CI](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36134145618)：
   同一测试文件的英文注释有多余连字符，应使用 `misread`。

这两项没有在 HDR 功能分支中修改；合并时请核实是否已由 GLM 修好，避免重复覆盖。
本分支不增加版本号、不创建标签、不发布 DMG。基线已经准备 `0.2.37` / build `48`，
但版本号出现在源码中不代表该版本已正式发布。
发布负责人尚待双方协调，不应两台机器同时创建同一版本的标签或上传资产。

整合后需保持本项目的全部发布门禁：完整 CI、更新与签名安装回归、前稳定版公钥验签、
六项资产草稿验全、公开更新源和完整 DMG 哈希校验。不能用本地回归通过代替正式发布。
