# 原生续播的 Core 生命周期集成测试

这不是完整 App 验收。夹具抽取实际 PlayerCore 的开片、原生准入、
停止／退出、替换、预览与兼容换核方法，并连接真实 Session、解码器、
sample-buffer output、libmpv、Receipt、Service 和文件发布 Store。
窗口／应用服务、历史缓存通知和偏好 UI 是明确的边界。

## 隔离与可信边界

- 只打开本轮构建目录里的合成红／蓝 H.264/AAC 视频及其逐案例副本。
- Service.shared 替换为本轮 UUID 隔离 UserDefaults suite；
  resumeLastPosition 注册默认值为 true，关闭续播通过真实 KVO 进入 Service。
  不读取 .standard 的续播值；案例结束删除唯一自有 suite，runner 退出也按
  owned-domain.txt 的严格 UUID 名称做清理。
- Utility.watchLaterURL 指向同一私有构建目录，与真实 MPV
  watch-later-directory 完全一致。MD5 使用 CryptoKit 实现相同的路径摘要规则；
  Utility.existingWatchLaterURL 则原样抽取生产实现。
- MPV 使用 config=no、隔离 config-dir、vo=null、ao=null、初始音量零。
  resume-playback=yes；真正加载生产 Store 写出的记录，没有手动设置 start/speed
  来伪造恢复。mpvQuit 边界提交真正 quit，观察实际 SHUTDOWN。
- 预览和退休阶段的屏障只阻塞真实 Session worker；发布屏障使用 Store 的
  NATIVE_RESUME_STORE_TESTING 观察点。均显式检查进入、限时释放与退出，
  不伪造 snapshot、文件结果或成功事件。

## 固定 230 项契约

labels.txt 固定每个唯一标签及次序；正向必须全部 PASS、child exit 0。
覆盖：

1. 暂停的非零位置／倍速停止保存，真实 MPV 重开恢复并消费记录，音量仍为零。
2. 直接退出、停止完成后退出、停止仍在 worker 排队时立即退出：
   实际 MPV 只退出一次，缓存／最近播放元数据只交付一次。
3. 换文件仅记录旧媒体且不复活旧最近记录；队列下一项及仅为兼容换核不保存。
4. 活跃预览、预览恢复 seek 仍排队时关闭，保存原基线；手动 seek 清掉临时基线。
5. generic capture／retire／FILE_LOADED／PLAYBACK_RESTART 四个阶段停止；
   后三阶段保留最新 owned seek 2.7 秒和倍速 1.5，不保存部分 MPV 的零值。
   迟到的旧事件不能再次执行已取消动作。
6. 真正文件发布前清进度、关闭续播、同路径新 owner，拒绝旧记录与迟到元数据；
   清最近记录独立于播放进度，保留可用进度但不复活最近记录。

限度：没有用户文件、真实外设／可闻音频、完整菜单和 App 生命周期验收；
窗口服务是测试边界，不代表 Spaces／真实 GUI 已通过。Session 的终止 snapshot
表示实际 worker 已应用的稳定状态，不承诺尚未执行的所有 UI 点击都成为 snapshot。

## 运行

    bash Tools/NativeResumeCoreTests/run.sh
    NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeResumeCoreTests/run.sh
    NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeResumeCoreTests/run.sh
    NATIVE_RESUME_CORE_NEGATIVE=drop-exit-save bash Tools/NativeResumeCoreTests/run.sh
    NATIVE_RESUME_CORE_NEGATIVE=drop-preview-checkpoint bash Tools/NativeResumeCoreTests/run.sh
    BUILD_ONLY=1 bash Tools/NativeResumeCoreTests/run.sh

可用 NATIVE_PLAYBACK_DEPS 指定经验证的隔离依赖。
产物保留在 build/native-resume-core.*/。编译、子进程退出、固定标签、
源码前后、生成源码／二进制、媒体及依赖摘要均须通过；每轮最多 150 秒。

负控只修改生成的生产方法副本：

- drop-exit-save：只撤 stop() 的保存请求。230 项中必须且只能失败固定
  49 项（缺记录、恢复／元数据连带失败，以及预期发布根本未发生的屏障检查）。
  shutdown() 和替换的保存请求仍保持原样，不能靠任意非零退出冒充成功。
- drop-preview-checkpoint：只撤预览恢复中的基线 checkpoint。230 项中必须
  且只能失败 checkpoint 存在性与该记录的三项，共 4 项。

## 本地证据

生产 Core d037183d5ac3ba8c4d398c4f43b5c468ef387bd56e4d81cbf6b53c7dc70d47be，
Service c2c9509704b6702da776f0304f51d437d9544b2c46af06a48a320154033a3418，
Session 06ecda97d3a1d88b6134c8a8e0e44210add6e70c4be0614452afa5593dc6f387。

| 模式 | 目录 | 结果 |
| --- | --- | --- |
| 普通 | ufKAS0 | 230 / 0，固定标签验证及 runner 退出 0 |
| ASan | ROXXht | 230 / 0，child 与 runner 退出 0 |
| TSan | mbpHDy | 230 / 0，child 与 runner 退出 0 |
| drop-exit-save | ZlQYKt | 230 项、精确 49 项失败；child 1、verifier 与 runner 0 |
| drop-preview-checkpoint | P8wDea | 230 项、精确 4 项失败；child 1、verifier 与 runner 0 |

五轮 source-before.sha256 的摘要完全相同：
1d168ef11259559a0390af78d60798229fc87f39d87c1f66d700742c5d41a49e。
每轮 source-diff.txt 均为空，生成物／合成源视频／依赖核验通过；
使用隔离依赖 build/native-av1-playback.7FMHum。
这些结果不继承此前或后续完整 App CI 的结果。

保留探索证据而不重标：
onQCZo 仅编译；
h3QCre 为 216 / 0、child 0，但因尚未建立标签契约而 wrapper 1；
NgMveZ 为较早 216 项 checkpoint 负控，实际 4 项失败但 verifier 尚未配置；
IYQzSk 为 230 项 stop 负控，实际 49 项失败但 verifier 尚未配置。
PSwpUG 为 230 / 4 checkpoint 负控，精确 verifier 已通过，但另一任务在执行
期间短暂修改共享 Route Boundary，source trap 正确返回 wrapper 1；
共享文件随后字节恢复，最终证据为 P8wDea，不将 PSwpUG 重标为同源通过。
这些都不是最终同源矩阵。
