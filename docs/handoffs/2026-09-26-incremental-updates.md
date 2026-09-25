# 增量更新与升级配置保留

## 范围与状态

- Base commit：`082d335f`（上一正式版 `v0.2.39` / build `50`）。
- Branch：`codex/incremental-updates`。
- 目标版本：`v0.2.40` / build `51`。
- 用户要求：减少升级下载量，保留原有配置；沿现有授权完成正式发布。
- 实现提交：`49534044`，标签 `v0.2.40` 指向该提交。
- **已于北京时间 2026-09-26 06:17:33 正式发布并完成公开交付核验。**
  不能据此声称用户已安装新版或每次升级都必定走增量。

## 实现

沿用已安装客户端的 Sparkle 2.10.0，使用官方 `BinaryDelta` 格式 4，不另写不安全的
文件覆盖器。不更改 Bundle ID、更新源、公钥或安装屏障。

1. 发布时下载上一稳定版完整包，核对固定仓库身份、大小、摘要和校验和，使用现有公钥
   验证旧 feed 与完整包后才只读挂载。
2. 验证新完整 DMG 与构建 App 的所有文件、权限和符号链接一致。生成补丁后实际应用到
   旧 App 副本，对新 App 全树比较并验代码签名；不只比较版本号。
3. 只有小于完整包的补丁才进入 feed；补丁、完整包和 feed 都独立签名。
   六个基础附件加所有声明的补丁／校验和必须在草稿中完整验证后才发布。
4. 客户端优先选择匹配旧 build 的增量，保留进度、安装前的工作保护及可推迟倒计时。
   补丁不适用或损坏时由 Sparkle 回退验签后的完整包，不能为省流量降低安全检查。

目前仅为上一稳定版生成一个补丁；跳过版本、修改了旧 App、补丁无体积收益时可能全量下载。
手动 DMG 安装仍是完整包。生产密钥仅由现有 CI 签名进程通过 stdin 接收，不进入测试或日志。

配置、快捷键、历史、模型和下载记录保持在现有 UserDefaults / Application Support，
不随 App 替换清理。修复两个迁移覆盖问题：缺少迁移标记不再导致重置明确保存的
自动更新开关、控制条位置、自动隐藏和剩余时间。新安装仅初始化缺失值。
`SUAutomaticallyUpdate=false` 仍用于可见下载与安全安装屏障，不能误改成静默替换。
系统授权受 ad-hoc 代码身份限制，不能承诺升级后 macOS 永远不再询问权限。

## 主要代码

- `other/download_previous_release.py`、`build_delta_update.py`：旧包认证、官方补丁、往返验证。
- `other/generate_update_feed.py`、`verify_appcast.py`：签名、严格 delta 元数据与逐包验签。
- `other/release_delivery.py`、`.github/workflows/ci.yml`：精确资产集、不可变上传、匿名完整下载。
- `iina/Updates/UpdatePolicy.swift`、`iina/PlayerChromePolicy.swift`：仅初始化缺失的配置。
- `Tools/AppUpdateIntegrationTests`、`Tools/SparkleUpdateTests` 和现有配置迁移测试：回归证据。

## 本地验证

以下命令使用独立测试 Python 环境和锁定的 Sparkle SDK；没有生产密钥、真实用户设置或媒体。

```sh
SPARKLE_TEST_ROOT=/path/to/pinned/Sparkle python -B -m pytest -q \
  Tools/SparkleUpdateTests/test_updates.py \
  Tools/SparkleUpdateTests/test_delta_builder.py \
  Tools/SparkleUpdateTests/test_delta_assets.py \
  Tools/SparkleUpdateTests/test_release_policy.py \
  Tools/SparkleUpdateTests/test_release_delivery.py
```

联合结果：**84 passed, 164 subtests passed，0 skipped**。包含真实签名 23 项、
真实补丁构建与安全回归 8 项、增量基包策略 14 项、发布连续性 19 项、交付 20 项。

```sh
SPARKLE_TEST_ROOT=/path/to/pinned/Sparkle python -B Tools/AppUpdateIntegrationTests/run.py --scenario delta-upgrade
SPARKLE_TEST_ROOT=/path/to/pinned/Sparkle python -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-delta
SPARKLE_TEST_ROOT=/path/to/pinned/Sparkle python -B Tools/AppUpdateIntegrationTests/run.py --scenario mismatched-delta
SPARKLE_TEST_ROOT=/path/to/pinned/Sparkle python -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-delta-and-dmg
SPARKLE_FRAMEWORK_DIR=/path/to/pinned/Sparkle/framework-parent bash Tools/AppUpdateTests/run.sh
bash Tools/PlayerChromeLifecycleTests/run.sh
bash Tools/HDRPreferenceTests/run.sh
bash Tools/VideoWindowSizingTests/run.sh
```

四个 delta 场景均已真实安装链路运行通过，测试 feed 与生产一致（delta enclosure 无额外
`sparkle:version`）。正常情况 HTTP 只请求 delta；坏补丁／不匹配旧包请求 delta 后再请求完整包。
两者都被篡改时旧 App 全树不变、无安装放行、无重启。成功场景仅一次重启，重启前后保留
隔离测试域的类型化偏好，以及合成的快捷键、书签、历史和模型标记；不等同于真实模型推理验证。
现有完整包更新和坏完整包拒绝场景也已通过，CI 会全部重跑。

迁移回归：AppUpdateTests 143 checks、PlayerChromeLifecycleTests 157 checks（含 ASan 和
Intel 10.15 类型检查）、HDRPreferenceTests 42 checks、VideoWindowSizingTests 70 checks。
两处迁移新增用例先在修复前复现失败，再在修复后通过。

## 正式发布证据

- [主线完整 CI 36192458001](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36192458001)
  通过；主线不执行正式发布步骤，不能单独当作发布证据。
- [正式标签 CI 36192556109](https://github.com/SeanLi-Coder/ChengYingPlayer/actions/runs/36192556109)
  三个任务全部通过，包含真实增量安装、坏补丁／旧包不匹配回退、双坏包拒绝、正式补丁往返、
  上一稳定版公钥验证，以及发布后匿名完整下载验证。
- [v0.2.40 正式发布](https://github.com/SeanLi-Coder/ChengYingPlayer/releases/tag/v0.2.40)，
  发布时间 `2026-09-25T22:17:33Z`，build `51`，精确八个附件：六个基础资产及补丁／校验和。
- 本机独立匿名核实 `/releases/latest` 指向 `v0.2.40`；从安装客户端的精确 feed 地址
  `/releases/latest/download/appcast.xml` 下载，并完整下载 DMG、补丁及两个校验和。
  大小和 SHA-256 均与发行元数据一致。匿名 REST API 本机额度耗尽（HTTP 403、remaining 0），
  因此发行元数据使用已认证 API 读取；实际 latest、feed 和全部更新载荷仍为匿名下载，未改网络策略。
- 以先前已校验的公开 `v0.2.39` 完整包为基线，旧公钥先验证公开新 feed、完整包和 delta，
  再只读挂载新完整包。实际应用公开补丁后，与公开新版逐文件比较 bytes / modes / symlinks 全部一致，
  新版与还原版的深度严格代码签名均通过。没有启动或覆盖用户已安装的播放器、读取真实设置或模型。

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| 完整 DMG | 167994145 | `b74b4c4a3147087fb954ef0ef9786be3736bc46e9d0da799de9dd11a8df55e89` |
| 从 build 50 的 delta | 997706 | `47c4cf9fcf95d120d921f2379fa34157906b3590e04b8bb37d65c8e72977b89d` |
| appcast.xml | 1981 | `e5177dc03deb64efb353787ef0f16b58ffa3c860ded6e83edbd247091e79fa12` |

此次真实发行增量约 **1 MB**，对比约 **168 MB** 的完整包减少 **99.4061%** 下载量。
这不是 fixture 的估计，不保证下一版相同比例。更旧版本、改过 App 的版本或损坏补丁可能走完整包。
功能发布完成；尚未在用户实际 M4 Max 上安装，不把临时测试 App 的设置／模型标记验证说成用户实机验收。
