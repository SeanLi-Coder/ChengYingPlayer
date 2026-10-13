# 新开文件与旧目录匹配任务的交接回归

测试抽取当前生产 `PlayerCore.openMediaURLs`、`checkTicket` 和
`AutoFileMatcher.addFilesToPlaylist` 的完整方法；只在临时测试单元中放宽
matcher 方法的访问范围。使用真实递归锁、生产 `Atomic` 与文件筛选策略，
不建立 `.app`、不打开窗口、不读取真实媒体或用户设置。

```sh
python3 -B Tools/MediaOpenAdmissionTests/run.py
python3 -B Tools/MediaOpenAdmissionTests/run.py --negative-control b931000b
python3 -B Tools/MediaOpenAdmissionTests/run.py --negative-late-cancel
python3 -B Tools/MediaOpenAdmissionTests/run.py --negative-matcher b931000b
python3 -B Tools/MediaOpenAdmissionTests/run.py --negative-post-append
python3 -B Tools/MediaOpenAdmissionTests/run.py --sanitize thread
python3 -B Tools/MediaOpenAdmissionTests/run.py --sanitize address
```

可控屏障将旧目录批次停在第一次 append 内。主线程只有在即将尝试获取同一把
锁时才允许旧操作继续，核实取消信号已经发布。无需以机器速度推断是否阻塞；
五秒超时只是测试死锁保护，不是性能通过门槛。

覆盖旧批次及时退出、append 后不再执行旧 move、显式新列表不被旧任务污染、
空目录／字幕／非本地输入不取消当前任务、预检及锁内准入失效、锁内票据失效、
单文件／批量／BD／播放列表的原有返回约定，以及已有原生退休和显式队列分流。
旧开片方法必须在“等锁前未取消”断言失败；旧 matcher 必须在“取消后仍 move”
断言失败，编译失败或其他失败不能作为负对照通过。
`--negative-post-append` 只撤掉 append 后的取消检查，保留其余全部修补。
`--negative-late-cancel` 只把当前方法的原子取消块移到获取列表锁之后，必须在
同一个取消顺序断言失败。CI 使用这两种单点变异，不依赖浅克隆中可能不存在的历史提交。
每次运行在独立的 `build/media-open-admission.*` 目录保留前后源码 SHA-256、
编译和测试日志、测试原始退出码与 runner 最终退出码；源文件变化会使验证失败。

这里替换了 MPV 命令边界和无关的原生生命周期，不证明真实解码、窗口首帧或
Movist 性能对比。既有原生核心和播放列表回归仍应分别运行。
