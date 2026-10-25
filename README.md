# IPA Depot

macOS 原生图形界面，用于登录 App Store 账号、搜索 App、下载最新版与历史版本 IPA。
底层调用内置的 [ipatool](https://github.com/majd/ipatool) v2.7.0 官方 Release 二进制（MIT）。

> 开发中（阶段二：界面层已完成，待验收）。使用说明与安装方式将在发布前补全。

## 功能（草稿）

- **登录 / 登出 Apple ID**：登录前的准备页说明密码只在本机使用、首次登录需下载组件、钥匙串授权请选「始终允许」；支持双重认证 6 位验证码；密码通过伪终端交给 ipatool，不进命令行参数、不写日志、不保存。
- **搜索 App**：按 iPhone / iPad / Mac 平台搜索账号所在地区的 App Store，显示图标、开发者、Bundle ID、当前版本、价格与平台。
- **历史版本**：列出全部历史版本（最新在上），版本号与发布日期按可见区域懒加载并缓存；可下载任一版本。
- **下载队列**：一次下载一个、其余排队；进度、大小、速度；暂停 / 继续（断点续传）/ 取消；完成后在访达中显示。免费 App 未加入账号时可一键领取免费许可后下载。
- **下载记录**：名称、Bundle ID、版本、外部版本 ID、大小、路径、完成时间；文件不在时灰显；可移除单条或清空。
- **设置**：下载目录（默认 `~/Downloads/IPA Depot`）、缓存占用与清理（只清本 App 的缓存）、关于与许可、检查更新（GitHub Releases）。
- 简体中文为主，附英文界面。

## 开发

```sh
brew install xcodegen
scripts/fetch-ipatool.sh          # 拉取并校验 ipatool，合并为 universal → vendor/ipatool/ipatool
xcodegen generate
xcodebuild -scheme IPADepot -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData
```

- 图标：`swift scripts/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset`（CoreGraphics 程序化生成）。
- 本地化：构建一次后运行 `python3 -I scripts/sync-strings.py --check`，检查 `App/Localizable.xcstrings` 是否有新 key 或缺英文。
- Debug 构建可用环境变量 `IPADEPOT_IPATOOL_PATH` 指定 ipatool、`IPADEPOT_DATA_ROOT` 指定数据目录（Release 构建忽略二者，只用内置 ipatool）。

## 许可与致谢

- IPA Depot：MIT，见 `LICENSE`。
- ipatool：MIT，Copyright (c) 2021 Majd Alfhaily，见 `vendor/ipatool/LICENSE`（随 App 打包为 `Contents/Resources/ipatool-LICENSE`）。
- 字体：标题与数字使用[阿里妈妈数黑体](https://fonts.alibabagroup.com)（淘宝（中国）软件有限公司，免费商用），许可原文见 `App/Resources/Fonts/阿里妈妈数黑体-许可.txt`（随 App 打包在 `Contents/Resources/Fonts/`）。字体不在本项目 MIT 许可范围内。
