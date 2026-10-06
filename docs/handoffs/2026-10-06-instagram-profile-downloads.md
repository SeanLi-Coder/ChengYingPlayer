# Instagram 主页批量下载交接

## 范围与使用

基于 `260dd077`，目标版本 `v0.2.65` / build `76`。用户以
`https://www.instagram.com/yiluntan_news/` 为测试案例，要求把该主页的全部视频与
图片下载下来。

新增原创适配器 `app/instagram.py`（GPL-3.0-or-later，不属于 MIT 上游快照），
观察站点自身页面脚本发出的分页 GraphQL 时间线响应，不复制第三方签名代码、不重放
私有签名 API、不绕过验证、不去水印。接入沿用既有队列、经验证的资产传输、代理、
进度与取消机制：`models.py` 增加 `INSTAGRAM` 平台值，`platforms.py` 识别严格校验
的主页与单帖 URL，`downloader.py` 增加发现与逐部件下载分派，`task_manager.py`
保持未完成主页发现可重试，`main.py` 脱敏分享跟踪令牌，前端三个文件增加平台标签、
本地化进度与错误提示及输入引导。

支持单个作品与作者主页批量下载。图集（carousel）逐成员展开为独立可重试部件。
探索页、话题页、故事、账号页、分享跟踪链接一律拒绝；`p/<shortcode>` 与已废弃的
`<post>/media/` 后缀识别为单帖，更深路径视为其它界面并拒绝，因此不会把首个片段
恰好形似 shortcode 的无关帖子当作单帖下载。

## 发现失效的根因与修复

首次实站验证时，发现阶段对目标主页报「无可验证作品」，而该主页实际有 442 篇。
逐层插桩定位到根因：适配器原先把每个请求经 `route.fetch()` 取回、再用
`route.fulfill()` 交还浏览器。对 Instagram 这类重前端页面，这会让加载停在约 67
个响应处不再推进；再滚动 20 次、累计 33 秒仍无新增，主页组件从未挂载，站点因此
从不发出时间线查询。

三组对照实验分离出因果：注册处理器但对每个请求调用 `continue_()`，加载 353 个
响应并发出时间线查询；完全不注册处理器，加载 345 个并发出；所有中继变体一个都没
发出。另外三种常见怀疑均已排除且失败表现完全一致——保留原始 cookie 头、在
fulfill 时剥离 `content-encoding`、不拦截图媒体子资源。所以成因是中继本身，不是
缺头或被拦的子资源。快手能容忍同样的中继，因为其页面轻得多。

中继原本提供的重定向保证被保留并加强：`continue_()` 不会为每一跳重定向重新进入
路由处理器，因此改由 `request` 事件对浏览器实际发出的每个请求重新套用受信任主机
白名单（真实主页实测 295/295，零个跨主机重定向）；`framenavigated` 事件记录主
框架真正提交的 URL，交由既有身份校验核对，观察的是最终渲染位置而非每个请求跳。
拦截图媒体、图片与字体子资源予以保留且实测无害：跳过 110 个图片请求的同时时间线
查询仍然发出，并把浏览器预算留给分页。

同时修正三处独立缺陷：帖子 URL 深度校验过松，`p/short/audio/123/` 会被当作帖子
`short` 接受，现要求恰好两段（或 `media` 后缀三段）；取消信号会被「无可验证媒体」
抢先，取消清空遍历后用户自己的停止会被报成站点问题，现优先响应取消；Instagram
的规范限流文案 `wait a few minutes` 未被识别，被误归为普通请求拒绝，现归入限流
并触发等待重试语义。

## 测试与实站验证

离线门禁（`/tmp/ig-venv`，与 CI 同款依赖）：

```sh
python Tools/DownloaderHelper/verify_vendor.py          # integrity verified
python -m ruff check Tools/DownloaderHelper --exclude vendor   # All checks passed
CHENGYING_REQUIRE_CHROME_UI=1 \
  python -m pytest -q Tools/DownloaderHelper/tests      # 1135 passed, 65 subtests
python Tools/DownloaderHelper/run_upstream_tests.py     # 1405 passed, exit 0
for t in DownloaderProxyUITests DownloaderChromeProfilesUITests \
         DownloaderDiagnosticsUITests DownloaderOutputIndexTests; do
  node Tools/$t/main.mjs                                # 四个全部 PASS
done
typos                                                   # 全仓库 PASS
```

新增 `tests/test_instagram.py` 共 78 项，覆盖 URL 识别与拒绝、适配器解析、身份校验、
中断保留已验证作品、限流分类、取消优先级、逐部件分派、原生放行守护、重定向跳校验
与真实字节传输。

`AI_COLLABORATION.md` 专门点名「`route.continue_()` 不等于每次自动重定向都会再过路由
检查」，所以重定向保证有两项专项回归：不可信跳必须阻断发现（该跳只以请求事件出现、
从不重进路由处理器），受信任域名上的跳必须放行。实站测量中重定向跳数为 0，即真实
站点未触发该路径，因此这两项保证由离线回归而非实站样本证明。

测试改动修正三处既有缺陷：`SimpleNamespace` 带 `__enter__` 属性无法充当上下文
管理器（dunder 方法按类型解析），改为真实的 `StubYoutubeDL`；打在类上的替身缺
`self`；构造下载器时 `cookie_browser` 重复传参。

新增的真实字节传输回归测试填补一个既有覆盖缺口：Instagram 与快手的图片测试此前
都 mock 掉 `_download_first_available_asset`，其下真实传输层
（`_open_xiaohongshu_response` 经锁定的 yt-dlp requests 处理器）从未被覆盖。新
测试用本地回环套接字驱动它，断言字节逐字落地并通过 FFmpeg 解码与声明尺寸校验。

实站验证（用户指定的公开主页，Chrome `Default` 登录态，本机系统代理）：

- URL 识别：6 个非法 URL 全部拒绝，主页正确接受并归一化。
- 发现：**成功**，69.0 秒枚举 1599 个可下载部件（1442 图片 + 157 视频），
  `discovery_complete=True`。站点确认列表结束，并诚实报告 442 篇中有 5 篇未在
  时间线返回（置顶、隐藏或已删除的作品无法从主页网格枚举），另有 3 篇属他人作者
  （协作贴）被跳过而非归到本作者目录。
- 视频下载：**成功** 3 个，均 1080x1920 VP9，实测时长与字节数一致
  （134.37s / 63672252 bytes，61.1s / 20909072 bytes，86.57s / 26448705 bytes），
  选择 dash 音视频合流。
- 图片下载：**成功** 3 个，均 1440x1920 JPEG（mjpeg），实测 435147、871806、
  453397 bytes，声明尺寸校验通过。第一张耗时 53.2 秒，其后两张 2.3 与 2.0 秒。

第一次运行时 2 个图片以 `SSL: UNEXPECTED_EOF_WHILE_READING` 失败而视频同时成功，
数分钟后本机代理对所有站点（含 google.com）彻底中断、直连与经代理均返回 000。
代理恢复后同一路径 6/6 全部成功，故该失败归因于代理上游退化，非代码缺陷。第一张
图片 53.2 秒的耗时也与代理刚恢复时的慢启动一致。

已离线排除的两项图片路径怀疑：图片传输确实取到代理（实测
`{'all': 'http://127.0.0.1:7897'}`），未绕过代理；真实传输层经回环套接字证明
正确（字节逐字一致、声明尺寸校验通过、服务器确实收到请求）。

下载的个人媒体已删除，未进入仓库。`.build/` 下的插桩脚本被 `.gitignore` 忽略，
只输出计数、尺寸与固定诊断类别，从不打印 cookie 值、账号标识、媒体地址或标题。

## 已知限制与剩余工作

图片下载缺少瞬时错误重试：`_download_first_available_asset` 只在一个资产的多个
候选 URL 之间切换，同一候选上的瞬时传输错误不会重试，而视频经 yt-dlp 自带重试。
该函数由小红书、抖音、快手与 Instagram 共用，改动风险与范围都超出本次任务，故未
处理。全量下载（1599 个部件）最终 0 失败，说明该限制在本次运行未触发；但它仍是
潜在缺陷，若后续复验再现间歇性 `UNEXPECTED_EOF`，应作为独立改动评估。

代理中断期间的发现失败被正确报为 `network_error` 且不回退直连，符合既有约定；
用户需在下载中心配置代理路由，引擎不会自动继承系统代理。

清单与文档已同步：`upstream-manifest.json` 刷新 9 个改动文件的集成哈希、登记
`app/instagram.py` 与 `app/static/styles.css`，`verify_vendor.py` 的
`PATCHED_FILES` 与 `INTEGRATION_FILES` 常量同步，`tests/test_vendor.py` 的集成
文件期望同步，`bundle_smoke.py` 的冻结 helper 资源自检清单纳入 `app/instagram.py`
（该模块由打包规格的整目录数据项与 `collect_all("app")` 自动带入，无需改规格），
`UPSTREAM.md` 新增 Instagram 章节记录枚举、中断、续传语义与上述原生加载实测结论。
快手文件未被本次改动修改（曾加的可选平台标签参数已回退，适配器改为原生放行后
不再复用该助手）。

## 全量下载交付（2026-10-06）

用户随后把要求升级为「全部下载成功、不能有失败项」。生产下载器走完整队列把目标
主页全部部件下载到桌面，最终 **1599/1599 完成、0 失败、2.27 GB**（视频 157 个
mp4、图片 1442 张 jpg）。独立于脚本自身计数的磁盘核查：零字节文件 0、JPEG 头全
有效、无重名、157 个视频经 ffprobe 时长全有效（合计 124.2 分钟）、1442 张图片尺寸
全部可解析、`progress.json` 与磁盘逐条对齐。文件名 0 个含缺陷不可见字符，20 个含
emoji 零宽连接符（U+200D，合法保留）。

站点声明 442 篇，实际可下载 437 篇本作者作品。差的 5 篇非故障：3 篇为他人作者的
联动/转发贴（安全设计按 author 不符正确跳过），2 篇主页网格中亦不存在（置顶/隐藏/
已删除）。主体 1599 个部件已全量下齐。

标题塌缩缺陷已修复：站点 `accessibility_caption` 对 408/437 篇只返回单个不可见
格式字符 U+2061，`_first_line` 误判其「非空」并采纳，导致文件名变成垃圾字符。改为
修剪行首尾不可打印字符、保留 emoji ZWJ，桌面最终 0 个缺陷字符、20 个合法 ZWJ。

## 发布链路上的 CI 失败定性

v0.2.65 首次标签前，主线 CI 出现两处失败，均与本适配器无关：

- `media-helper-tests` 步骤 21「Test private download-center adapter」首次失败，
  失败点是原生 Swift 断言 `DownloadCenterTests/main.swift:492`——一个 8 秒超时的
  `waitForPage` WebKit 时序断言（`-AppleLanguages (en)` 英文模式）。该断言依赖的
  `.item-files`/`#refresh-button` 不在本次改动范围；本地已覆盖同一 `en` 语言矩阵并
  通过 295 项。下一次主线运行该步骤 `completed/success`，坐实为偶发超时，非代码缺陷。

- `build-apple-silicon` 步骤 7「Build playback libraries from pinned source」失败，
  根因是固定源 `download.savannah.gnu.org` 的 freetype 源码包连接超时（curl 28），
  且其官方 `download-mirror` 同时不可达。校验正确地失败关闭（不完整的归档不匹配固定
  SHA256 而被丢弃）。这不是本适配器问题，而是第三方源站瞬时不可达。修复：
  `fetch_verified_source` 对 freetype 在 curl 退出码 6/7/28 且 URL 等于固定源时，
  回退到已用于 dav1d 的 buildroot 镜像（字节级校验和一致），连接受限
  （connect-timeout 15、max-time 120、retry 0）且仅限 HTTPS；校验和不符、TLS 错误或
  其它传输失败仍不回退，镜像无法替换为不同字节。发布清单仍记录规范 Savannah 地址，
  镜像只是传输回退。新增 10 个测试覆盖该分支，并以变异测试验证（移除回退、放行 TLS
  错误回退、校验和不符仍回退，各自都令对应用例失败）。修复已本地端到端验证：主源
  不可达时回退镜像、落地 SHA256 一致、无残留、二次调用命中缓存。

## 发布状态

发布状态：离线门禁全部通过，主线与标签 CI、签名安装、增量全树还原及匿名公开交付
尚待验收。发现、视频与图片的实站端到端下载均已通过（6/6 抽样成功）。
