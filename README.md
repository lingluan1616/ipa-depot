# IPA Depot

macOS 原生图形界面，用于登录 App Store 账号、搜索 App、下载最新版与历史版本 IPA。
底层调用内置的 [ipatool](https://github.com/majd/ipatool) v2.7.0 官方 Release 二进制（MIT）。

> 开发中（阶段一：引擎层）。使用说明与安装方式将在发布前补全。

## 开发

```sh
brew install xcodegen
scripts/fetch-ipatool.sh          # 拉取并校验 ipatool，合并为 universal → vendor/ipatool/ipatool
xcodegen generate
xcodebuild -scheme IPADepot -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData
```

## 许可

- IPA Depot：MIT，见 `LICENSE`。
- ipatool：MIT，Copyright (c) 2021 Majd Alfhaily，见 `vendor/ipatool/LICENSE`（随 App 打包为 `Contents/Resources/ipatool-LICENSE`）。
