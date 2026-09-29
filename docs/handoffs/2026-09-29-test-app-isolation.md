# 发布验证工作区防重复

Base commit: `17902b4f`

Branch: `codex/prevent-test-app-duplicates`

## 范围

用户要求应用搜索不再积累同名 ChengYing。上一轮九个入口来自公开增量验证留下的
测试 App，不是已证实的安装器重复安装。本轮不修改播放器二进制、版本、更新身份或用户配置。

- `other/test_app_workspace.py`：唯一受管 `.noindex` 目录及 ownership 校验；成功、异常与
  正常取消退出时检查进程／挂载、逐路径注销（包括嵌套 App）、按 bundle ID 复核，再删除
  自己生成的临时目录。注销后再检查占用与 ownership，拒绝 symlink、变化的目录和未完成状态。
- `other/verify_public_release.py`：替代本地一次性脚本，永久证据与临时 App 分开；保持旧公钥、
  完整包与每个增量签名、逐文件还原一致性、代码签名、冻结 helper/API/剪辑检查。
  沿用 GitHub 重定向 allowlist，限制小响应与下载体积／时间；只有清理成功才写总成功报告。
- 打包、增量生成和合成回归接入同一生命周期。Sparkle 2.10 默认的展开缓存也被隔离：
  仅签名生成器子进程使用独立 `CFFIXED_USER_HOME`，不改 `HOME` 或全局环境；传入密钥前
  核对固定布局及 Foundation 实际缓存路径，预置完整校验过的 App，避免工具自行挂载／强制卸载。
- CI 加入新的工作区与公开验证生命周期回归；README 与协作规则要求使用统一入口。

## 本机验证

以下命令均从仓库根目录执行；使用 CPython 3.13，签名测试仅生成一次性合成密钥：

```sh
CHENGYING_RUN_LAUNCHSERVICES_TESTS=1 python3.13 -B Tools/SparkleUpdateTests/test_app_workspace.py
python3.13 -B Tools/SparkleUpdateTests/test_public_workspace.py
env -u SPARKLE_ED25519_PRIVATE_KEY SPARKLE_TEST_ROOT=/absolute/path/to/pinned/Sparkle python3.13 -B Tools/SparkleUpdateTests/test_delta_builder.py
env -u SPARKLE_ED25519_PRIVATE_KEY SPARKLE_TEST_ROOT=/absolute/path/to/pinned/Sparkle python3.13 -B Tools/SparkleUpdateTests/test_updates.py
python3.13 -B Tools/DMGPackagingTests/test_packaging.py
python3.13 -B Tools/SparkleUpdateTests/test_release_policy.py
python3.13 -B Tools/SparkleUpdateTests/test_release_delivery.py
python3.13 -B Tools/SparkleUpdateTests/test_delta_assets.py
git diff --check
```

工作区 37 项（含真实 LaunchServices 注册／注销）、公开验证生命周期与下载边界 7 项、
真实增量 10 项、签名 23 项、DMG 打包 17 项均通过；已有发布策略、交付与旧资产回归通过。
早期发现 macOS 将“未注册”的 `-10814` 写入不同输出流，已仅兼容精确路径和该固定错误；
其他错误仍失败，另以真实 NSWorkspace 查询复核。保留原签名失败测试断言，修正其过宽的
subprocess mock，使真实挂载与清理执行，不让模拟签名错误吞掉安全清理。

公开 v0.2.47 安装包的匿名交付、旧公钥验签、增量全树还原和冻结 helper/API/四次剪辑通过。
最终完整清理未通过：本机安全扫描占用一个只读测试卷，普通卸载被拒绝。没有强制卸载、
停用安全软件或伪造总成功记录；该受管目录已精确注销，需占用解除后正常卸载再处理。
失败的七个纯合成测试工作区在核实无挂载／无运行后已移入系统废纸篓；原生产安装与数据未动。
2026-09-29 21:02（北京时间）Spotlight 和 LaunchServices 均只返回正式安装的 App。

## 边界

本轮属于开发／验证工具修复，不创建新的播放器标签或重发 v0.2.47。
不把本地测试通过称为 CI 或正式发布成功。后续修改仍需按实际 CI 结果记录。
工具只处理自己创建的目录；手动 Xcode 输出应使用独立 `.noindex` DerivedData，不能为清理
而修改 App 的签名身份或扫描删除用户手动安装的副本。SIGKILL、断电及系统长期占用需明确报告，
不能承诺退出处理一定运行。
