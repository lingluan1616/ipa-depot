# 阶段四（发布前小修）进度

更新：2026-10-27 · 状态：**已完成，待主会话验收**

## 改动清单

| 项 | 结果 | 位置 |
|---|---|---|
| 1 登录准备页文案 | 第三条改为「钥匙串授权会弹两次，都选「始终允许」」：授权框不在登录时出现，登录成功后**第一次搜索弹一次**、**第一次查看历史版本或下载再弹一次**（两条不同的钥匙串记录），两次都选「始终允许」后不再询问。示意图保留未动。中英文均已写入 | `App/Views/LoginSheet.swift`、`App/Localizable.xcstrings` |
| 2 准备页第四条 | 「商店地区跟随账号」：搜索与下载以账号所在地区的 App Store 为准；想下其他地区的 App，需登出后换该地区的账号登录。图标 `globe.asia.australia` | 同上 |
| README 同步 | 「首次打开」里的钥匙串段落改为两次弹出的准确描述（小标题改为「首次登录与首次使用时会发生两件事」）；常见问题「搜不到某个 App」补「想下其他地区的 App，需要先登出，再用该地区的 Apple ID 登录」；常见问题「下载中断了怎么办」补失败任务的「重试」与跨启动保留；English 段落的钥匙串与地区说明同步 | `README.md` |
| 3 失败任务保留 | **队列**：`DownloadQueueItem` 新增 `lastFailure: IpatoolError?`，失败（非取消）时记下；`resume`（重试）清除；`restore(_:id:progress:lastFailure:addedAt:)` 以 `.paused` 放回并带上失败原因。失败 → 仍在列表、`.tmp` 保留；重试 = 同一任务、同参数重跑（ipatool 用 `.tmp` 续传）；取消 = 从列表移除并删 `.tmp`（原有逻辑，已补测试）。**持久化**：`PersistedDownload` 新增可选 `failure: PersistedFailure?`（`kind` 字符串、中文 `message`、ipatool 原文 `raw`；未知 kind 按 `.unknown`；阶段三旧文件无此字段照常读取）。`persistableEntries` 放行 `.failed`（排除 `.licenseRequired`），暂停中的条目若带上次失败原因也一并写入。**界面**：失败显示「失败：<中文原因>」（红色）+ 红色进度条（保留已下载比例）+「重试」「取消」按钮 +「查看原始错误」；重启恢复为「已暂停 · 上次失败：<中文原因>」，按钮显示「重试」，「查看原始错误」仍可用；重试后失败原因清除 | `Sources/IPADepotCore/DownloadQueue.swift`、`DownloadQueueStore.swift`、`App/Logic/DownloadsViewModel.swift`、`App/Logic/Services.swift`（协议签名）、`App/Views/DownloadsView.swift` |
| `.licenseRequired` / 付费 App | 处理不变：仍弹领取许可提示（付费 App 只提示购买），不写入 `queue.json`（有测试覆盖） | — |
| 4 版本号 | `MARKETING_VERSION` 仍为 0.1.0；`CFBundleVersion` 由 `scripts/build-release.sh` 生成（本次 202610261937）。`CHANGELOG.md` 0.1.0 补「失败任务可重试并跨启动保留」一条，准备页一条同步改为新文案要点 | `CHANGELOG.md` |
| Debug 冒烟入口 | `SmokeDriver` 新增 `p4LoginIntro` / `p4Fail` / `p4Restore` 三个模式（`#if DEBUG`，Release 无此代码，`strings` 核对为 0） | `App/Views/SmokeDriver.swift` |

## 测试

```
xcodegen generate                                                       → OK
xcodebuild -scheme IPADepot -configuration Debug … build                → BUILD SUCCEEDED
  warning 仅 appintentsmetadataprocessor「Metadata extraction skipped」（Xcode 自带工具，已知问题），工程告警 0
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData → TEST SUCCEEDED（连跑两次均全绿）
  IPADepotCoreTests  Executed 70 tests, with 3 tests skipped and 0 failures   （原 66 + 新 4）
  IPADepotTests      Executed 39 tests, with 0 failures                       （原 35 + 新 4）
  合计 109 个（原 101 + 新增 8），0 失败
python3 -I scripts/sync-strings.py --check                              → exit 0（155 个 key，新增 6 个均有英文；旧的准备页第三条文案标 stale）
```

新增测试（8）：
- Core `Tests/IPADepotCoreTests/Phase4CoreTests.swift`：失败 → 保留且记下原因、`.tmp` 不删，重试复用同一任务同参数并清除原因；带失败原因恢复为暂停、不自动开始，取消删 `.tmp`；取消失败任务删 `.tmp`；`PersistedFailure` 往返、文件里存中文 message、阶段三旧文件可读、未知 kind 视为 unknown。
- App `Tests/IPADepotTests/Phase4ViewModelTests.swift`：失败任务留在列表、状态「失败：…」、`isRetry`、重试同参数；失败任务连同原因与 totalBytes 写入 `queue.json`、`.licenseRequired` 弹提示且不写入、`persistNow` 不变；从文件恢复为暂停并显示「已暂停 · 上次失败：…」、原始错误、25% 进度，重试后文件里原因清除；取消失败任务删 `.tmp` 并从文件移除。
- 修改：阶段二 `testRowTextMapping` 的失败文案断言改为新格式「失败：…」；App 测试替身 `FakeDownloadTask` 增加 `emit(_:)`（发进度事件）。

## Release 产物（`build/release/`，2026-10-27 03:38 构建，0.1.0 / CFBundleVersion 202610261937）

| 文件 | 大小（字节） | sha256 |
|---|---|---|
| `IPA-Depot-0.1.0-macos-universal.zip` | 40,833,756 | `be52f236684ee1a360638c4a00712abc81035136416c3da216e9e2f0de77dbd5` |
| `IPA-Depot-0.1.0-macos-universal.dmg` | 45,510,256 | `03d98287c6259e58424b9f78c95647f39dc9c23e7b6ac13e26869d1c61fefcab` |
| `IPA-Depot-0.1.0-macos-universal.zip.sha256` | 102 | — |
| `IPA-Depot-0.1.0-macos-universal.dmg.sha256` | 102 | — |
| `IPA Depot.app` | 约 87 MB | 本地验收用，不上传 |

核对：`shasum -a 256 -c` 两个 OK；`hdiutil verify` checksum VALID；`lipo -info` 主程序、`Resources/bin/ipatool`、`IPADepotCore.framework` 均 `x86_64 arm64`；`codesign --verify --deep --strict` → valid on disk / satisfies its Designated Requirement；`CFBundleShortVersionString=0.1.0`；Release 主程序 `strings | grep IPADepotSmoke` = 0；`en.lproj/Localizable.strings` 含新英文文案。旧的 `build/release/` 已整体移到 `~/.Trash/ipa-depot-release-old-20261027/release`。

### Release 启动冒烟

- 直接运行主程序，启动参数 `-hasCompletedFirstLogin NO -ApplePersistenceIgnoreState YES`（参数域、不写偏好）。**原因：真实偏好里 `hasCompletedFirstLogin = 1`（用户今天已登录），不加此参数 Release 启动会调用内置 ipatool `auth info` 读钥匙串。**
- 20 秒内逐秒检查：`pgrep -P <pid>` 与 `pgrep -f Resources/bin/ipatool` 始终无结果；`CGWindowListCopyWindowInfo` 看到主窗口 1040×700。
- 结束：`kill -TERM`（退出码 143，与阶段三相同做法；未用 AppleScript quit，避免触发自动化授权）。之后无残留进程。
- 真实数据 `~/Library/Application Support/IPA Depot/` 运行前后逐文件 md5 一致；`defaults read app.ipadepot.mac hasCompletedFirstLogin` 前后均为 1。

## Debug 冒烟（`docs/screenshots/phase4/`，日志 `smoke-log.txt`）

运行：Debug 包，`IPADEPOT_IPATOOL_PATH` 指向假 ipatool 脚本 `build/smoke-tools/ipatool`（**只把 `--version` 转给 `/opt/homebrew/bin/ipatool`**；`download` 第一次写 3,000,000 字节 `.tmp` 后打印 `ERR error="Get …: unexpected EOF"` 退出 1，第二次在同一 `.tmp` 追加 1,000,000 字节后 sleep；auth / search / purchase 等其余子命令一律拒绝），`IPADEPOT_DATA_ROOT=build/smoke-data`，启动参数 `-hasCompletedFirstLogin NO -downloadDirectory build/smoke-downloads`（参数域）。说明：任务书写的 `IPADEPOT_IPATOOL_PATH=/opt/homebrew/bin/ipatool` 无法模拟失败，故用包装脚本代替，且整个冒烟期间真实 ipatool 一次都没被调用（没有调用 `--version` 的页面）。

| 模式 | 结果 | 截图 |
|---|---|---|
| `p4LoginIntro` | 准备页四条说明 + 示意图，文案与布局正常；ipatool 调用 0 次 | `p4-01-login-intro-sheet.png`（`p4-01-login-intro.png` 为背后主窗口） |
| `p4Fail` | 任务失败后留在「进行中」：红字「失败：网络连接失败……」+ 重试 / 取消按钮 +「查看原始错误」+ 3 MB；退出后 `queue.json` 含该条与 `failure{kind:networkUnreachable, message:<中文>, raw:<原文>}`，`.tmp` 保留 | `p4-02-failed.png` |
| `p4Restore` | 重启后为「已暂停 · 上次失败：网络连接失败……」，按钮为重试，未自动开始；点重试 → 假 ipatool 第二次调用参数与第一次**完全一致**（见 calls.log），`.tmp` 由 3 MB 续写到 4 MB，状态「正在下载」；退出时子进程被终止、无残留，`queue.json` 仍保存该条（失败原因已清除） | `p4-03-restored.png`、`p4-04-retrying.png` |

图标为占位（冒烟不联网，不取图标）。

## 未完成

无。

## 已知问题

1. 持久化放行**所有**非「需要许可」的失败，包括重试大概率无效的类别（如 `packagePlatformMismatch`、`verificationFailed`、`appNotFound`）。它们同样恢复为暂停 + 上次失败原因，用户可取消。见待决 1。
2. 失败文案前缀「失败：」对所有失败类别都加（含 `.licenseRequired`，其领取提示弹窗逻辑不变）。
3. 失败的网络类错误中文文案较长，在下载行里最多显示两行（点「查看原始错误」后展开），截图中两行已能完整显示。
4. 沿用阶段三：`hdiutil create` 在 macOS 27 打印弃用提示；Release 冒烟以 `kill -TERM` 结束。
5. 运行 Debug / Release 时 macOS 会更新真实偏好 `app.ipadepot.mac.plist` 中的窗口位置（阶段二起已知），本次未写入其他键。

## 待主会话决定

1. 是否把「重试大概率无效」的失败类别（`packagePlatformMismatch`、`verificationFailed`、`appNotFound`、`notLoggedIn`、`passwordTokenExpired` 等）排除在跨启动保存之外，只保存网络类 / 未知类失败。目前按任务书「失败任务保留为暂停态」全部保存（仅排除 `.licenseRequired`）。
2. `.licenseRequired` 的状态文字是否也去掉「失败：」前缀以保持与阶段三完全一致（当前带前缀，弹窗与不保存的处理未变）。
3. 本次新增的 Debug 冒烟模式（`p4LoginIntro` / `p4Fail` / `p4Restore`）是否保留在 `SmokeDriver` 中（同阶段三决定 ②，已默认保留）。

## 收工清理

- `build/` 只剩 `downloads/`（ipatool 官方包缓存）与 `release/`。
- 已逐项移入 `~/.Trash/ipa-depot-test-cleanup-20261027-phase4/`（未用 rm、未用通配符）：`build/DerivedData`、`build/smoke-data`、`build/smoke-downloads`、`build/smoke-shots`、`build/smoke-tools`、`build/tmp-phase4`（英文译文 json、Release 构建日志、真实数据目录前后 md5 快照）、`$TMPDIR/app.ipadepot.mac.savedState`。
- 系统临时目录里 `IPADepot*` 为 0 个（测试 tearDown 自删）；无残留 IPA Depot / 假 ipatool / sleep 进程。
- 旧 Release 产物在 `~/.Trash/ipa-depot-release-old-20261027/release`。
- 过程说明：做真实数据目录快照时有一条命令误把 md5 列表写到了仓库外的 `~/Documents/claude/ignore`（以及 `/tmp/claude-501/ipadepot-before.txt`），当即移回 `build/tmp-phase4/` 后随之进入上述废纸篓目录，仓库外已无残留。
