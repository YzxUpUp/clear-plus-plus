# Clear++

Clear++ 是原生 macOS 应用卸载工具，可以查看软件及关联文件的磁盘占用。

- 扫描独立应用、App Store 应用、通过 `.pkg` 安装的软件和 Homebrew 软件包。
- 支持名称搜索、安装来源多选，以及按名称或磁盘占用排序。
- 卸载前可逐项检查偏好设置、缓存、日志和应用支持数据。普通应用和勾选的关联文件会移到废纸篓。
- 支持浅色与深色，默认跟随系统。

部分驱动和后台组件需要厂商卸载器。自定义的应用目录可通过「文件 → 添加扫描位置…」补扫。

## 下载安装

从 [GitHub Releases](https://github.com/YzxUpUp/clear-plus-plus/releases/latest) 下载 macOS ZIP，解压后将 `Clear++.app` 拖到「应用程序」。需要 macOS 14 或更新版本，支持 Apple 芯片和 Intel 芯片。

下载包使用临时签名，未经 Apple 公证。首次启动可能出现系统安全提示。[Apple 支持](https://support.apple.com/102445)

## 从源码构建

安装 Xcode Command Line Tools 后，在仓库目录执行下方命令。构建结果位于 `dist/Clear++.app`。

```sh
./build.sh
```

构建同时包含 Apple 芯片和 Intel 芯片的版本时，使用 `./build.sh --universal`。
