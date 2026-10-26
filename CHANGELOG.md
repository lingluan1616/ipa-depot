# 更新日志

本文件记录 IPA Depot 的所有重要变更，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.1.0] - 2026-10-26

首个公开版本。

### 新增

- 登录 / 登出 Apple ID：登录前的准备页（密码用途、首次组件下载、钥匙串授权何时弹出及「始终允许」、商店地区跟随账号），支持双重认证 6 位验证码；密码经伪终端交给 ipatool，不进命令行参数、不写日志、不保存。
- 首次登录成功前，启动时不读取钥匙串（不调用 `auth info`），避免在看到说明前弹出系统授权框；登出后恢复这一行为。
- 按 iPhone / iPad / Mac 平台搜索账号所在地区的 App Store，显示图标、开发者、Bundle ID、版本、价格与平台。
- 历史版本列表：最新在上，版本号与发布日期按可见区域懒加载并缓存，可下载任一版本。
- 下载队列：一次一个、其余排队；进度、大小、速度；暂停 / 继续（断点续传）/ 取消；免费 App 可一键领取许可后下载。
- 下载队列跨启动保存：排队中、已暂停与退出时正在下载的任务写入 `queue.json`，下次启动恢复为「已暂停」，继续时用 `.tmp` 续传；退出时终止下载子进程且不再启动新的任务。
- 失败任务可重试并跨启动保留：下载失败（如网络中断）的任务留在列表，显示「失败：原因」，可「重试」（同参数从 `.tmp` 续传）或「取消」（删除 `.tmp`）；退出时连同失败原因写入 `queue.json`，下次启动恢复为「已暂停」并注明上次失败的原因。
- 下载记录：名称、版本、大小、路径、完成时间，文件不在时灰显。
- 设置：下载目录、本 App 缓存清理、关于（App 与 ipatool 版本、项目地址）、许可（IPA Depot MIT、ipatool MIT、阿里妈妈数黑体法律声明）、通过 GitHub Releases 检查更新。
- 简体中文界面与英文界面。
- 内置 ipatool 2.7.0 官方 Release（arm64 + amd64 合并为 universal，sha256 锁定）。
- 发布工具：`scripts/build-release.sh`（universal Release、ad-hoc 签名、zip / dmg / sha256）、`scripts/set-owner.sh`、GitHub Actions CI 与发版工作流。

### 已知限制

- 未经 Apple 公证，首次打开需在「系统设置 › 隐私与安全性」点「仍要打开」，或执行 `xattr -dr com.apple.quarantine`。
- 只支持单个账号。
- 不自动更新，只提示有新版本。
