# M4 AV1 免开发环境验收包

此目录只新增打包器、离线测试和独立启动器，不修改现有 AV1 runner、生产代码或播放默认值。
固定复用已验收的 non-sanitizer `native-av1-tests`，不重新编译、不改 `install_name`、不重新签名。
该二进制是 thin arm64，Mach-O 最低系统版本为 **macOS 26.0**；不能声称支持更早版本。

## 开发机生成

```bash
python3 -B -m unittest discover -s Tools/NativeAV1Tests/Portable -v
python3 -B Tools/NativeAV1Tests/Portable/build.py
```

默认输入为已验证的 `build/native-av1-tests.lnilr6qr` 和 `build/native-av1-playback.7FMHum`。
可用 `--evidence`、`--deps` 指向这些**相同身份**的原始输入；不会自动接受新的二进制、库或素材。
打包器核验现有 source/generated 清单、normal-run 7486/0 记录、CYN/main 源文件、二进制、五个库和
五个合成素材的精确 SHA，并解析 Mach-O 依赖闭包。换新候选必须显式 review 后更新锁定记录。
Python 3.11+ 仅在开发机打包/测试时需要，目标机不需要 Python。

产物独占 `build/m4-av1-acceptance.*.noindex/`，包含完整文件夹、ZIP 和 ZIP SHA-256。
ZIP 在执行任何本机检查前生成，不夹带本机报告。这里只生成本地文件，不上传、不发布、不安装 App。
ZIP 校验用于检测传输损坏，不是发行者认证；本包没有 Developer ID 签名或公证。
脚本与 manifest 同包，SHA 不能抵御同时恶意改写脚本和 manifest，也不能证明发行者身份。

## 许可证与对应源码

实际 FFmpeg 配置启用 `--enable-gpl --enable-version3`，且静态解析依赖；五个 dylib 不等于只有
五种软件。包内 `Legal/` 保留项目 LICENSE/NOTICE、实际构建的原始 notices、锁定 source manifest、
配置，以及配套 `Corresponding-Source.tar.gz`。源码归档包含 CYN/测试程序的精确代码、现有编译
runner、锁定的 16 份完整播放栈源压缩包、原补丁和 build recipe、同次 build record 与逐文件 SHA。
这是完整播放 recipe 的源码超集，不声称 mpv/libplacebo 等都链接进本测试 CLI。

打包复用已有 `verify_playback_distribution.py`、`locked_sources()` 和 source cache 锁校验，
遵循 `package_release_source.sh` 的对应源码材料策略；不直接调用它的 App 专用外壳，因为后者固定
读取根 `deps`，还打包本验收程序不含的 media/helper 运行时。所有源码只能来自已有缓存，缺失就失败。
源归档保留源码和重建脚本以满足再分发材料要求，但 M4 运行时无需展开源码或安装开发工具。

## 目标 M4 Max

复制 ZIP 整包，解压后双击 `Run-M4-AV1-Check.command`。也可以在终端执行：

```bash
/bin/sh "/完整路径/M4-AV1-Acceptance/Run-M4-AV1-Check.command"
```

目标只需要 macOS 26+ 自带 `/bin/sh`、`/usr/bin/perl` 及 Perl 核心模块。
不需要源码、Xcode、Homebrew、网络、Python 或安装到 Applications。
系统阻止运行时只记录提示，不自动去除隔离、授权或修改安全设置。

`--verify-only` 仅进行完整性与平台门禁核查，输出 `VERIFIED_NOT_RUN`，不是硬解成功。
真实运行强制传 `hardware`；两种位深 1738 项检查、首次硬件帧计数、完整退出码、实际 dylib 路径以及
运行前后 SHA 都符合才可 `PASS`。M2 的软件回退明确是 `FAIL`。缺输出、重复摘要、错误计数、错误
位深、崩溃、超时、缺文件、改动文件、符号链接或未知库路径均不作为通过。

启动器用 `env -i` 清空用户环境；子进程仅指定本包 `lib` 的 `DYLD_LIBRARY_PATH`，不追加用户或全局目录。
原二进制的开发机绝对 RPATH 保留以维护原始身份，但检查实际 dyld 加载路径必须是包内五库；不会把
开发机路径或系统 fallback 当作可接受闭包。这里只允许系统 `/System/Library`、`/usr/lib` 依赖。
未知系统输出格式也会安全失败，不能忽略硬解或依赖证据。

`reports/run-*/report.json` 每次独立保存，仅含相关 OS 版本、arm64、真实计数、退出和完整性结果。
原始 stdout/stderr 仅在内存中分类，不写入报告；不收集序列号、用户名、账号、媒体路径或网络数据。
报告不自动上传。`actual` 数组顺序为 native opens / software opens / fallback / frames / VT / hardware。

此包仍只覆盖小型合成 8/10-bit AV1 的解码、seek、同 FD restart 和同 URL reopen。
完整 App、4K 长时、能耗、实体 HDR 屏及真实声卡仍需另验。目标 M4 真机结果必须单独回传，开发机的
离线测试、`--verify-only` 或 M2 软件回退都不能替代它。

## 离线测试界限

`test_portable.py` 用临时假进程测试分类器与环境清理；所有测试素材明确是假数据，不是硬解证据。
覆盖安全通过基线和软件回退、signal、超时、非零退出、摘要不完整/重复、计数错误、错误 strict mode、
实际库来源错误、前/后文件改变、缺文件、额外库、符号链接、manifest 改动及路径穿越等反例。
测试输出绝不合并进目标机硬件验收记录。
