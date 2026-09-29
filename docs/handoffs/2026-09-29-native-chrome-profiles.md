# 本机 Chrome Profile 修复交接

## 基线与范围

- 基线：`3cbf3a09`，分支：`codex/douyin-native-profile-repair`。
- 拟发布：`v0.2.48` / build `59`；本文初稿时尚未发布。
- 用户本机截图报告 `chrome_profile_missing`。元数据检查确认已保存的
  `Default` 不存在；用户明确确认其目标账号位于另一个现存配置。
- 只测试用户指定的单视频，不采集主页或其他账号，不提交真实媒体、网页、
  Cookie、账号资料、签名 URL、私人路径或用户诊断原文。

## 修补

- 原生下载设置使用实际 Chrome 目录列表，替换固定示例输入；不读取账号邮箱、
  Cookie 内容或 Local State。数据库存在不等于登录成功或能够解密。
- 元数据扫描有界、拒绝相关符号链接，权限／存储／扫描失败和确认不存在分别提示。
- 显式配置缺失时，新任务创建前即阻止并要求重新选择、保存，不等排队后报错。
- 配置预检与创建共用原配置锁，并发保存不能偷偷改变已检查的任务身份。
- 旧任务重试继续保留原身份；修改配置后须从原链接创建新任务。
- 自动模式及已保存的关闭 Cookie 模式保留原行为，不自动换成其他账号。
- 真实浏览器测试发现并修复异步配置加载覆盖控件的竞态：可见 Profile／Cookie
  草稿独立保存，提交前再同步原处理器，不让晚到的初始响应改掉用户选择。
- 保留上游引擎、登录权限、最高画质验证、重试取消、代理、数据目录和任务历史；
  本轮未修改 vendor 或来源清单。

## 验证与边界

- 新增目录／API／并发提交／UI 回归及冻结版合成 Profile 自检。
- 真实 Chrome UI 7 项通过，零跳过（包括文字、轨道、空白标签和键盘切换）；
  Node UI 51 项通过；API／目录／自检／host
  组合 102 项通过。原生更新 UI 143 项、签名更新 23 项通过；完整包、增量包及
  四项篡改／不匹配负例均完成真实安装或拒绝验证，用户配置保留检查通过。
- 原有完整上游隔离回归 1405 项通过，来源完整性检查通过。
- 下载 helper 全套 889 项及 62 个子测试通过（最后一项标签交互回归另测）；
  不提交个人账号测试资料。
- 所有离线 Cookie 测试仅用合成数据；真实站点测试单独、显式使用用户确认的配置。
- 本机真实测试已通过 Cookie 提取并识别唯一目标作品，没有匿名回退。
  网站返回的待验证 4K 候选约 2.06 GB，首次传输在约 972 MB 后重新开始；
  初稿时尚未完成完整下载，不将此写成播放或最高画质验收成功。
- 上一基线 CI `36574077640` 在合成 DMG 创建时返回 `hdiutil` exit 1，
  本机对应 23 项签名回归通过。移除该 fixture 的 `-quiet` 以保留下次真实错误，
  没有盲目重试、弱化验签、回退隔离或强制清理。
- 正式发布仍须完整 CI、签名更新和匿名公开交付验证；记录应按实际结果更新。

## 复测命令

```sh
build/player-v29-tests.nD75s9/bin/python -B -m pytest -q -rs Tools/DownloaderHelper/tests
build/player-v29-tests.nD75s9/bin/python -B Tools/DownloaderHelper/run_upstream_tests.py
node Tools/DownloaderChromeProfilesUITests/main.mjs
node Tools/DownloaderProxyUITests/main.mjs
build/player-v29-tests.nD75s9/bin/python -B -m ruff check Tools/DownloaderHelper --exclude vendor
python3 -B Tools/DownloaderHelper/verify_vendor.py
bash Tools/DownloadCenterTests/run.sh
```

测试环境路径是本机示例，不要求其他机器创建同名环境。
真实 Chrome UI 必须记录执行结果，不能把缺少 Chrome 时的 skip 当作通过。
冻结 helper 重建后还须执行 `--self-test` 和 `smoke_helper.py`；
更新身份、自动更新偏好、增量与完整包回退都不得为发布而修改。
