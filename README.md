# Clear++

[中文](#中文) · [English](#english)

## 中文

Clear++ 是一款原生 macOS 应用卸载工具，可以查看软件及关联文件的磁盘占用。

- 扫描独立应用、App Store 应用、通过 `.pkg` 安装的软件和 Homebrew 软件包，分别显示程序文件和关联文件的占用。
- 按名称搜索，可同时筛选多个安装来源，并按名称或磁盘占用排序。
- 卸载前二次确认，可逐项检查和取消勾选偏好设置、缓存、日志及应用支持数据。普通应用和勾选的关联文件会移到废纸篓。
- 支持浅色、深色和跟随系统，默认跟随系统。应用界面为简体中文。

部分驱动和后台组件需要厂商卸载器。自定义的应用目录可通过「文件 → 添加扫描位置…」补扫。

### 下载安装

从 [GitHub Releases](https://github.com/YzxUpUp/clear-plus-plus/releases/latest) 下载 macOS ZIP，解压后将 `Clear++.app` 拖到「应用程序」。需要 macOS 14 或更新版本，支持 Apple 芯片和 Intel 芯片。

下载包使用临时签名，未经 Apple 公证。首次启动可能出现系统安全提示。[Apple 支持](https://support.apple.com/102445)

### 从源码构建

安装 Xcode Command Line Tools 后，在仓库目录执行下方命令。构建结果位于 `dist/Clear++.app`。

```sh
./build.sh
```

构建同时包含 Apple 芯片和 Intel 芯片的版本时，使用 `./build.sh --universal`。

## English

Clear++ is a native macOS app uninstaller that shows how much disk space apps and their related files use.

- Scan standalone apps, App Store apps, software installed from `.pkg` installers, and Homebrew packages. See separate disk usage figures for program files and related files.
- Search by name, filter by multiple installation sources at once, and sort by name or disk usage.
- Review preferences, caches, logs, and application support data before confirming an uninstall. Deselect any related files you want to keep. Regular apps and selected related files are moved to the Trash.
- Choose Light, Dark, or System appearance. The default follows your system setting. The app interface is in Simplified Chinese.

Some drivers and background components require the vendor's uninstaller. To scan custom app folders, choose **File → Add Scan Location** (「文件 → 添加扫描位置…」).

### Download and install

Download the macOS ZIP from [GitHub Releases](https://github.com/YzxUpUp/clear-plus-plus/releases/latest). Unzip it and drag `Clear++.app` into Applications. Clear++ requires macOS 14 or later and supports Apple silicon and Intel Macs.

The download is ad hoc signed and has not been notarized by Apple. macOS may display a security prompt when you first open it. [Apple Support](https://support.apple.com/102445)

### Build from source

Install the Xcode Command Line Tools and run the command below from the repository directory. The app is built at `dist/Clear++.app`.

```sh
./build.sh
```

To build a universal app for both Apple silicon and Intel, run `./build.sh --universal`.
