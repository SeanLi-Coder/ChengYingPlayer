# 原生续播 Service / Receipt 隔离测试

这组测试验证真实 `NativePlaybackResumeService`、`NativePlaybackResumeReceipt`、`NativePlaybackResumePoint` 与 `NativePlaybackResumeStore` 的组合；不启动 ChengYing、不读取用户视频、真实应用配置或播放记录，也不调用网络。

## 运行

```sh
bash Tools/NativeResumeServiceTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeResumeServiceTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeResumeServiceTests/run.sh
```

每次运行创建一个独立的 `build/native-resume-service.XXXXXX` 证据目录，包含源码前后 SHA-256、生成源码与可执行文件 SHA-256、编译结果、每个子进程的原始结果及退出码、精确验证器结果和配置清理结果。失败证据也保留。默认目录不会被清理或覆盖。

## 真实边界与隔离方式

- 正向测试对 Service 源码只替换一处静态 `shared` 初始化：显式使用测试根目录和独立 `UserDefaults`，不使用 `.standard` 或 `Utility.watchLaterURL`。除这个配置边界外，Service / Receipt / Point 使用实际生产实现。
- `Preference.Key.resumeLastPosition` 在独立边界文件中保留相同的配置键名；实际使用 Foundation `UserDefaults(suiteName:)`、真实 KVO 注册、后台线程上的 `set` 和真实 KVO 回调，不模拟观察通知。
- 每个测试场景创建唯一的 `com.chengying.resume-service-test.<UUID>` 域，先将域名记录到本次目录的 `owned-domains.txt`，再写入偏好。测试结束逐一清除；runner 的退出处理另外运行一个清理程序，只接受该固定前缀加合法 UUID 的已登记域，并验证持久域已为空。不会重置标准配置或其他应用配置。
- Store 使用真实 POSIX 临时文件发布路径。仅 `NATIVE_RESUME_STORE_TESTING` 条件下的发布前同步钩子用来确定取消、清除和 opt-out 相对于提交的时序；钩子不改变 Store 的所有权、序列化、文件写入、状态检查或结果。
- Receipt 的媒体 URL 是临时目录内的合成名称，只作为身份标识，不打开媒体。已有冲突记录由测试创建，运行后验证 SHA-256 不变。
- 每轮还单独对没有测试宏的真实 Store 与配置隔离后的 Service 执行 `x86_64-apple-macos10.15`、Swift 5、`-warnings-as-errors` 类型检查；运行测试使用本机架构。这不是 Intel 机器或 macOS 10.15 的运行时验收。

## 145 项断言覆盖

- Point 拒绝非有限值、负时间、超出时长和非法速度；对轻微 EOF 时钟越界限幅。
- 退出意图在最终采样前后到达，以及 `finishIfRequested` 早于采样时，完成回调均正确交付；不会提前丢弃采样。
- 兼容内核切换仅采样，不自行保存；随后明确关闭才保存其所属位置。
- 剪辑预览的基准位置优先于临时时钟；authoritative nil 在采样前后都不得回退到其他时钟。
- 重复结束、并发等待者和 completion 内重入不会重复写入；`claimResultDelivery()` 只允许已完成 receipt 消费一次元数据结果，并且不吞掉等待者的 completion。
- nil 采样不能被第二次采样复活；初始关闭续播的 nil ticket 在重新启用后不能复活；同一文件只允许最新 receipt 发布。
- 发布前 invalidate、真实 off-main opt-out、真实 false→true KVO 变化以及清除记录均阻止旧写入复活。
- 最近记录和播放进度的 epoch 各自独立；清除失败仍使旧 progress epoch 失效，实际错误结果传回调用方。
- 冲突记录不会覆盖；KVO observer 不会形成保留环，释放后仍可修改对应的隔离偏好。
- 正常结束后清除每个隔离偏好域；回调、重复完成与受保护文件身份分别有断言。

这些断言属于 Service / Receipt 层：epoch 变化只证明调用方能发现失效，不能单独证明 PlayerCore 的 LastPlayed / cache 副作用正确。后者必须由 Core 层测试覆盖。

## 负控与防误报

每个负控只在本次证据目录生成的 Service 副本中修改一个保护点；真实生产源文件不修改。各负控仍必须完整运行 145 项断言，退出码为 1，并且仅允许预先列明的语义断言失败：

| 负控 | 故意破坏的保护 | 精确失败数 |
| --- | --- | ---: |
| `premature-finish` | 采样前提前结束 | 3 |
| `overwrite-baseline` | 最终时钟覆盖已指定基准 | 4 |
| `ignore-authoritative` | 丢弃 authoritative nil 意图 | 4 |
| `save-compatibility` | 不检查明确保存请求 | 3 |
| `ignore-kvo` | 不响应实际偏好变化 | 7 |
| `ignore-epochs` | 清除时不更新 epoch | 3 |
| `duplicate-delivery` | 元数据结果允许重复消费 | 5 |

`verify.py` 比较完整失败多重集、断言总数、唯一完成摘要和真实子进程退出码；任何超时、崩溃、`HARNESS_ERROR`、缺失/额外断言或 sanitizer 诊断都不算负控成功。`test_verify.py` 的 4 项自测专门验证验证器拒绝错误退出、截断结果和错误语义；其合成输入不作为 Service 运行证据。

## 本地证据与范围限制

当前验证源码身份：

- Service：`c2c9509704b6702da776f0304f51d437d9544b2c46af06a48a320154033a3418`
- Store：`776eae5caea1ce313ea4df2d9f5825642f3e9b4b56c51e281d21546453194712`

三轮最终同源证据：

| 模式 | 证据目录 | 正向结果 | 七组负控精确失败数 | runner |
| --- | --- | --- | --- | --- |
| 普通 | `build/native-resume-service.abABgj` | 145/0 | 3/4/4/3/7/3/5 | 0 |
| AddressSanitizer | `build/native-resume-service.1U4eIF` | 145/0 | 3/4/4/3/7/3/5 | 0 |
| ThreadSanitizer | `build/native-resume-service.gTGnGT` | 145/0 | 3/4/4/3/7/3/5 | 0 |

三轮源码清单完全一致，源码前后 SHA-256 相同，生成物哈希复查全部通过；每轮 4 项验证器自测通过、生产模式 Intel 10.15 类型检查退出 0、未发现 sanitizer 诊断。每轮 8 个子进程各自登记的 20 个隔离偏好域均由独立清理程序确认已清除，cleanup 退出均为 0。这里的 0 失败指正向逻辑，负控失败是预设的敏感性证据。

早期 `build/native-resume-service.HzW71u` 保留了旧负控源码锚点失配的 runner 失败；该轮不能作为完整通过。随后 `loSjP5`、`1SSYFD` 是 claimResultDelivery 接口加入前的中间结果，不替代当前同源验收。

这组测试不验证完整 App 的退出流程、真实窗口/预览画面、原生解码器读回时钟、PlayerCore 的所有权路由、已发布包、真实用户的权限或偏好迁移。MPV 实际加载/消费 watch-later 的独立证据见 `Tools/NativeResumeInteropTests` 与 `Tools/NativeResumeStoreTests`；不得把本套测试通过写成播放内核替换或完整续播验收完成。
