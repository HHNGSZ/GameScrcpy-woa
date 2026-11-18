# Windows on ARM 构建

GameScrcpy 有两条 Windows 构建线：x64（默认，`msvc-*` 预设）与 ARM64（`arm64-*` 预设，Windows on ARM 原生运行）。两条线用同一份源码，差别只在处理器相关的依赖二进制、一个编译开关和打包参数。

## 与 x64 的差别

| 项 | x64 | ARM64 | 原因 |
|---|---|---|---|
| 编译器 | `cl`（Hostx64 → x64） | `cl`（Hostx64 → arm64） | 交叉工具集，主机仍是 x64 |
| Qt | `msvc2022_64` | `msvc2022_arm64` + `QT_HOST_PATH` 指向前者 | 交叉编译：moc、rcc、qmlcachegen 只能在 x64 主机上跑 |
| 识图内核 | AVX2 + 标量后备 | 只有标量 | `Simd.cpp` 的 CPUID 检测是 x86 专有；`KernelsAvx2.cpp` 不参与编译 |
| FFmpeg | x86_64 + NASM + dav1d | aarch64，无汇编、无 dav1d | MSVC 的 aarch64 汇编要走 armasm + gas-preprocessor，这一版不做；AV1 用 FFmpeg 自带解码器 |
| 硬件解码 | D3D11VA | D3D11VA（同样开启） | 投屏的真实路径，两种处理器都由 GPU 完成 |
| SDL3、libusb | x64 预编译产物 | 各自从源码编出 arm64 版 | `tools/build_sdl3.ps1 -Arch arm64`、`tools/build_libusb.ps1 -Arch arm64` |
| TypeScript | `typescript-win32-x64` | `typescript-win32-arm64` | 原生 `tsc.exe`，不靠模拟层 |
| adb | x64 | 仍是 Google 发的那份 32 位 adb，走 Windows 的 x86 模拟层 | Google 的 platform-tools 不发布 ARM64 版；adb 只在连接手机时短暂占用，模拟层足够 |
| 测试 | 本机跑 | 本机跑不了（x64 主机不能执行 ARM64 程序），装到设备上跑 | 见下 |

## 部署 Qt 运行库

`windeployqt` 在目标套件里是 ARM64 程序，在主机套件里只认自己那套路径，所以交叉构建两样都用不上它。做法是：拿主机套件的 `windeployqt.exe`，另外放一份可重定位的主机 `qtpaths.exe` 与 `qt.conf`，`qt.conf` 把 `Prefix` 指向 ARM64 套件，再用 `--qtpaths` 让 windeployqt 从 ARM64 套件里取库、插件和 QML 模块。`src/app/CMakeLists.txt` 在检测到 `QT_HOST_PATH` 与目标套件不同时自动这么办。

## 构建步骤

准备：Visual Studio 2022 或更新，装「使用 C++ 的桌面开发」与 **MSVC v143 ARM64 生成工具**（`Microsoft.VisualStudio.Component.VC.Tools.ARM64`）；Qt 6.10 的 `msvc2022_arm64` 套件和一份 `msvc2022_64` 套件（主机工具用）；CMake 3.28 以上、Ninja、Python 3.10 以上。

```powershell
$env:GS_QT_DIR = 'C:\Qt\6.10.1\msvc2022_arm64'
$env:GS_QT_HOST_DIR = 'C:\Qt\6.10.1\msvc2022_64'
. .\tools\dev-env.ps1 -Arch arm64
cmake --workflow --preset arm64-release
```

`tools/dev-env.ps1 -Arch arm64` 自己拼出 ARM64 的 `INCLUDE`、`LIB`、`PATH`，不用 `vcvarsamd64_arm64.bat`——那个批处理要通过 `reg.exe` 读注册表找 SDK，在禁止运行 `reg.exe` 的机器上会失败。没给 `GS_QT_HOST_DIR` 时脚本会按 `msvc2022_arm64` → `msvc2022_64` 的命名推一份。

三个二进制依赖先在同样的环境里各编一次（只需一次，产物提交进仓库）：

```powershell
.\tools\build_ffmpeg.ps1 -Arch arm64
.\tools\build_sdl3.ps1 -Arch arm64
.\tools\build_libusb.ps1 -Arch arm64
```

## 打包

```powershell
.\tools\package.ps1 -Arch arm64
```

写出 `dist\GameScrcpy-<版本>-arm64-portable.zip` 与 `dist\GameScrcpy-<版本>-arm64-setup.exe`。安装包用 Inno Setup 的 `ArchitecturesAllowed=arm64`，只装在 ARM64 设备上。

在 x64 主机上打包时有三件事做不了，脚本会跳过并说明：

- `gs.exe --version` 与 `--smoke-test` 起不来（主机跑不了 ARM64 程序），这两项留到设备上手工确认；
- 示例扩展（`sdk\samples`）是 `gs.exe pack` 写出来的，同样跑不了，ARM64 包里没有它们；
- `gs-server.apk` 要在 `build\arm64-release\bin` 里。手机端是纯 Java，不挑处理器，从同一版本的 x64 安装里拷一个过来即可；没放时脚本只告警，不悄悄写出一个连不上手机的包。

`dxcompiler.dll` 与 `dxil.dll` 不随包发布：Qt 从 Windows 自己取（`--no-system-dxc-compiler`），否则 windeployqt 会把主机那份 x64 的拷进 ARM64 包里，而 ARM64 进程加载不了 x64 DLL。`icuuc.dll` 同理（`--ignore-library-errors`）：Qt 用的是 Windows 自带的 ICU，windeployqt 会试着去拷 `system32\icuuc.dll`。它这一拷有时成功——于是 ARM64 目录里出现了一个 x64 的 `icuuc.dll`，运行时 Qt 会先找到它然后加载失败——所以交叉构建在部署之后还会跑一次 `tools/prune_foreign_dlls.py`，把不是 ARM64 的 DLL（以及 windeployqt 中断留下的 `*.dll.XXXXXX`）从输出目录里删掉。

## 在设备上验证

```powershell
.\GameScrcpy.exe            # 主窗口、投屏、键位编辑器
.\gs.exe --version
.\gs.exe check <方案文件夹>  # 类型检查用的是 arm64 的 tsc.exe
```

测试程序与测试数据同样随构建产出（`build\arm64-release\bin`），拷到设备上可以直接跑 `ctest`。

## 已知限制

- 识图（找图、找色）在 ARM64 上用标量内核，比 x64 的 AVX2 慢；功能一致。
- 不接手机时软件解码 1080p H.265 在 8cx Gen 3 这类芯片上可能吃紧；接手机后走 D3D11VA 硬件解码，没有这个问题。
- 原生扩展（`.gsext` 里的 DLL）必须自己编 arm64 版并写进 `contributes.native.dll["arm64"]`，`gs validate` 会核对 PE 头里的机器类型。
