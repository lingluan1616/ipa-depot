# 阶段三（收尾功能 + 打包 + 发布准备）进度

更新：2026-10-26 · 状态：**已完成，待主会话验收**（Release 包的界面冒烟未做完，原因见「未完成」）

## 已完成

| 项 | 结果 | 位置 |
|---|---|---|
| A1 首次启动不碰钥匙串 | `UserDefaults` 的 `hasCompletedFirstLogin`。为假：`bootstrap()` 不调用 `auth info`，直接显示未登录；搜索在未登录时显示「尚未登录 / 登录…」空态，不调用 ipatool（历史版本只能从搜索结果进入）。点登录 → 准备页 → 账号密码 → 成功后置真。为真：启动照常 `auth info`。登出成功后置假（失败不改） | `App/Logic/AppModel.swift`（`firstLoginKey`、`hasCompletedFirstLogin`、`bootstrap`、`beginLogin`、`logout`）；`KeyValueStoring` 加 `bool(forKey:)` |
| A2 下载队列持久化 | `~/Library/Application Support/IPA Depot/queue.json`：`{"version":1,"items":[…]}`，原子写（`Data.write(.atomic)`）。每条含 id、appID、名称、Bundle ID、版本号、external version ID、purchase、输出路径、`--platform` 值、界面平台、是否免费、已知总大小、加入时间。保存排队中 / 进行中（含停止中、校验中）/ 已暂停；完成与失败不保存。每次队列快照变化时与上次写入内容比较，变了才写 | `Sources/IPADepotCore/DownloadQueueStore.swift`（`PersistedDownload`、`DownloadQueueStore`）、`AppPaths.queueFile`、`App/Logic/DownloadsViewModel.swift`（`startObserving` 恢复、`persist`、`persistNow`） |
| 恢复与续传 | 启动时 `DownloadQueue.restore(_:id:progress:addedAt:)` 以 `.paused` 放回，不自动开始；进度显示 `.tmp` 当前大小与已知总大小。点继续 = 同参数重跑（ipatool 用 `.tmp` 续传）。恢复的输出路径计入同名占用，新任务会避开。取消照旧删除 `.tmp` 并从 `queue.json` 移除 | `Sources/IPADepotCore/DownloadQueue.swift` |
| 退出处理 | `NSApplication.willTerminateNotification` → `persistNow()` + `queue.terminateRunningTasks()`（同步、加锁，不经过 actor）：SIGTERM 正在运行的子进程（按暂停处理，`.tmp` 保留），并置「正在退出」标志，**之后不再启动任何排队任务**（冒烟时发现：不加这个标志，退出途中会拉起下一个下载并成为孤儿进程，已修复并补测试） | `AppModel.prepareForTermination`、`DownloadQueue.terminateRunningTasks`、`RunningTaskBox` |
| B3 Release 脚本 | `scripts/build-release.sh`：读 `project.yml` 的 `MARKETING_VERSION`（0.1.0），`CURRENT_PROJECT_VERSION` = UTC `YYYYMMDDHHmm`；`xcodegen generate` → 任务书指定的 `xcodebuild … -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO build` → 拷到 `build/release/IPA Depot.app` → 对主程序、内置 ipatool、IPADepotCore 逐个 `lipo -info` 检查 → `codesign --force --deep -s -` → `codesign --verify --deep --strict` → `ditto -c -k --keepParent` → `hdiutil create … -format UDZO`（临时目录含 App 与 `Applications` 软链接，用完删）→ 各自 `.sha256` | `scripts/build-release.sh` |
| B4 仓库地址集中 | `App/Logic/ProjectInfo.swift`：`repositoryOwner`（占位值）、`repositoryName = "ipa-depot"`、`placeholderOwner`（判断是否已配置，脚本不改这一行）、`owner`/`projectURL`/`releasesURL`/`displayURL`。旧的 `ProjectInfo` 已从 `SettingsViewModel.swift` 移出；`UpdateChecker` 的 repo 改从这里读 | `App/Logic/ProjectInfo.swift` |
| B4 set-owner | `scripts/set-owner.sh <用户名>`：校验 GitHub 用户名格式；只改写 `repositoryOwner` 那一行，并把 README 里 `github.com/<当前 owner>/ipa-depot` 换成新的；可重复执行。已在 `build/` 下的副本上测过（占位 → octo-cat → newname，非法名退出码 2），真实文件未改动 | `scripts/set-owner.sh` |
| B5 CI | `ci.yml`：push 到任意分支与 PR，`macos-15`：checkout → `brew install xcodegen` → `scripts/fetch-ipatool.sh` → `xcodegen generate` → Debug 构建 → 测试。`release.yml`：推送 `v*` 标签 → 同样准备 → `scripts/build-release.sh` → `softprops/action-gh-release@v2` 上传 `build/release/*.zip/*.dmg/*.sha256`（**草稿**，见待决 3）。本机未执行，`ruby -ryaml` 解析通过（python 无 yaml 模块） | `.github/workflows/` |
| C6 README | 正式版：一句话介绍 + 三张截图（04 搜索、05 历史版本、02 准备页，已逐张核对账号区为「Apple ID / •••@•••」）→ 功能 → 安装与首次打开（仍要打开 5 步、「已损坏」时的 xattr 备用命令、首次组件下载约 56 MB、钥匙串「始终允许」）→ 使用说明 → 网络说明（`p*-buy.itunes.apple.com`、`files.pythonhosted.org`、`swcdn.apple.com`，建议代理）→ 常见问题（license is required、password token is expired、account is disabled、2FA、地区、续传、找不到钥匙串）→ 免责与使用边界 → 致谢（ipatool MIT、阿里妈妈数黑体及法律声明、a23bc/ipatool-gui 设计参考）→ 开发（保留原内容并补发版/set-owner/数据位置/CI）→ 许可 → English | `README.md` |
| C7 文档 | `CHANGELOG.md`（Keep a Changelog，0.1.0 条目）；`docs/RELEASING.md`（准备 → 改版本号 → 构建 → 本地验收命令 → 打标签走 Actions → 手动上传备用步骤与 `gh release` 命令 → 发布后） | 仓库根、`docs/` |
| C8 关于页许可 | 设置页新增「许可」分组三行：IPA Depot（MIT，许可全文）、ipatool（链接 + 许可全文）、阿里妈妈数黑体（不在 MIT 范围内，法律声明）。App 自身 `LICENSE` 作为资源打进 `Contents/Resources/LICENSE`（`project.yml` 加一条 resources） | `App/Views/SettingsView.swift`、`SettingsViewModel.License`/`licenseText` |
| 本地化 | 新增 10 个文案全部有英文；`python3 -I scripts/sync-strings.py --check` 退出码 0（151 个 key）。旧 key「开源组件」等已标 stale | `App/Localizable.xcstrings` |

### 验收命令结果

```
xcodegen generate
xcodebuild -scheme IPADepot -configuration Debug -derivedDataPath build/DerivedData clean build   → BUILD SUCCEEDED
  warning 只有 2 行，都是 Xcode 自带工具 appintentsmetadataprocessor 的「Metadata extraction skipped」（阶段一已知问题 9），工程告警 0
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData                           → TEST SUCCEEDED
  IPADepotCoreTests  Executed 66 tests, with 3 tests skipped and 0 failures
  IPADepotTests      Executed 35 tests, with 0 failures
  合计 101 个（原 86 + 新增 15），0 失败
scripts/build-release.sh                                                                          → exit 0
python3 -I scripts/sync-strings.py --check                                                        → exit 0
grep -rn "<owner>" App Sources README.md                                                          → 无输出
grep -rn OWNER_PLACEHOLDER（排除 build、.git）→ 只有 App/Logic/ProjectInfo.swift、README.md、scripts/set-owner.sh
```

### 新增测试（15 个）

- Core（6，`Tests/IPADepotCoreTests/Phase3CoreTests.swift`）：`queue.json` 编码解码与字段、文件缺失/损坏/未知新版本时视为空、`PersistedDownload.request` 与由 `.tmp` 推算的恢复进度；队列 `restore` 为暂停且不自动开始、继续时用同一请求、重复恢复被忽略；取消恢复项删除 `.tmp`；`terminateRunningTasks` 按暂停终止且不再启动下一个排队任务。
- App（9，`Tests/IPADepotTests/Phase3ViewModelTests.swift`）：首次启动不调 `auth info`（`FakeAuth.infoCount == 0`）且显示未登录；标志为真时启动调用一次并显示账号；首次启动搜索先引导登录、不调用搜索服务；登录成功置真、登出置假；登录失败保持为假；排队/进行中保存、完成后移出；从文件恢复为暂停（进度 25%、平台、名称）且继续用同参数、新任务避开恢复项文件名；取消恢复项删除 `.tmp` 并更新文件；内容未变化时不重复写。
- 另改了阶段二的 `testUpdateCheck`：不再写死占位地址，按 `ProjectInfo` 是否已配置分别断言（填 owner 后仍能通过）。

## Release 产物清单（`build/release/`，2026-10-26 05:27 构建，CFBundleVersion 202610252127）

| 文件 | 大小（字节） | sha256 |
|---|---|---|
| `IPA-Depot-0.1.0-macos-universal.zip` | 40,817,657 | `29527b1e64713411808b5860a8e640d88f14f906f6e92b67ad1d6cb964432aa4` |
| `IPA-Depot-0.1.0-macos-universal.dmg` | 45,501,476 | `f131922bda6cc4961699ab0968047c8a3d5d911ca1d2fb74b49b5b0513227cf2` |
| `IPA-Depot-0.1.0-macos-universal.zip.sha256` | 102 | — |
| `IPA-Depot-0.1.0-macos-universal.dmg.sha256` | 102 | — |
| `IPA Depot.app` | 约 87 MB | 本地验收用，不上传 |

核对结果：
- `lipo -info`：主程序、`Resources/bin/ipatool`、`Frameworks/IPADepotCore.framework/IPADepotCore` 均为 `x86_64 arm64`。
- `codesign --verify --deep --strict --verbose=2` → `valid on disk` / `satisfies its Designated Requirement`；`codesign -dv` → `flags=0x2(adhoc)`、`Signature=adhoc`、无 runtime；`codesign -d --entitlements -` 无内容（无沙盒）。
- `spctl -a -vv` → `rejected`（ad-hoc 未公证，符合预期）。
- `shasum -a 256 -c` 两个 OK；`hdiutil verify` → checksum VALID。
- `Contents/Resources` 含 `LICENSE`、`ipatool-LICENSE`、`Fonts/`（字体 + 法律声明）、`bin/ipatool`、`AppIcon.icns`、`en.lproj`；`CFBundleShortVersionString=0.1.0`。
- Release 主程序里 `strings | grep IPADepotSmoke` 为 0（Debug 冒烟代码没有进 Release）。
- Release 构建日志里的 warning 同样只有 appintentsmetadataprocessor 两行；`hdiutil create` 另打印一条弃用提示（见已知问题 2）。

## 冒烟

### Debug 冒烟（`docs/screenshots/phase3/`，日志 `smoke-log.txt`）

运行方式：`IPADEPOT_IPATOOL_PATH` 指向 `build/smoke-tools/ipatool` 包装脚本（逐条记录被调用的子命令；`download` 子命令直接 `exec sleep`，**不联网、不下载**；其余转给 `/opt/homebrew/bin/ipatool`），`IPADEPOT_DATA_ROOT=build/smoke-data`，下载目录用启动参数 `-downloadDirectory build/smoke-downloads`（参数域，不写偏好），`-IPADepotSmokeMode <模式>` 触发 Debug 专用 `SmokeDriver` 的阶段三模式。

| 模式 | 结果（包装脚本记录的 ipatool 调用） | 截图 |
|---|---|---|
| `firstLaunch`（真实偏好里没有该键 = 假） | 启动后 `signedOut`；搜索「音乐」→ `signedOut` 空态；打开准备页再关闭；设置页 ipatool 2.7.0。**全程只有一次 `--version`，没有 `auth info`**（= 首次启动不读钥匙串的冒烟证据） | `p3-01-first-launch`、`p3-02-first-launch-search`、`p3-03-login-intro-sheet`、`p3-04-settings` |
| `signedIn`（启动参数 `-hasCompletedFirstLogin YES`，只在参数域，不写偏好） | 启动即 `auth info --format json --non-interactive`，侧栏显示已登录（截图遮挡为 Apple ID / •••@•••） | `p3-05-signed-in` |
| `queueAdd` | 加入两个任务（谜底黑胶 3.8.5、QQ音乐最新版）：第一个立即开始（假 ipatool 只 sleep），第二个排队；然后退出。`queue.json` 写入两条；退出后没有残留子进程，也没有拉起第二个下载 | `p3-06-queue-added` |
| `queueRestore` | 重开后两条都是「已暂停」、可继续；**这次启动没有任何 ipatool 调用** | `p3-07-queue-restored` |

说明：队列空闲时加入任务会立刻开始（阶段二设计如此），所以没有「加入但不开始」的入口；冒烟用假 ipatool 承接 download，验证了「排队中」和「进行中退出」两种状态都按暂停恢复。第一次跑 `queueAdd` 时发现退出途中会启动第二个任务（留下孤儿 `sleep`，已手动结束），修复后重跑即上表结果。

`defaults read app.ipadepot.mac hasCompletedFirstLogin` 冒烟前后都是「不存在」，真实偏好未被写入。

### Release 冒烟（`build/release/IPA Depot.app`，只做不碰钥匙串的部分）

- 直接运行主程序约 20 秒：进程存活，`CGWindowListCopyWindowInfo` 能看到它的主窗口；**`pgrep -P <pid>` 无子进程，`pgrep -f Resources/bin/ipatool` 全程无结果** → 启动没有调用内置 ipatool（没有 `auth info`，不会弹钥匙串框）。
- 内置二进制 `Contents/Resources/bin/ipatool --version` → `ipatool version 2.7.0`。
- 真实数据目录 `~/Library/Application Support/IPA Depot/` 运行前后都只有阶段一的空 `state/`。
- 结束方式：`kill -TERM`。

## 未完成

1. **Release 包的界面截图与点击核对没有做**：未登录侧栏、点开准备页、设置页显示的内置 ipatool 版本都需要看到窗口。`screencapture -l` 没有屏幕录制权限（报 could not create image from window）；申请 computer-use 控制 IPA Depot 被拒绝，按规矩没有重试，也没有用 AppleScript 发按键（会触发辅助功能授权）。同样的界面在 Debug 包里已截图（上表），Release 只多了「只认内置 ipatool」这一点，已用进程检查证明启动不调用它。请主会话或用户在验收时打开 `build/release/IPA Depot.app` 看一眼这三处。
2. 没有在 Release 包里登录、搜索、下载（任务书禁止）。

## 已知问题

1. **队列持久化的范围**：按任务书只保存排队 / 进行中 / 暂停；**失败的任务（例如网络中断）不保存**，退出后丢失，它的 `.tmp` 会留在下载目录（下次同名下载会另起序号）。见待决 1。
2. `hdiutil create -volname … -format UDZO` 在 macOS 27 上打印弃用提示（建议改用 `diskutil image create`），目前仍正常生成并通过 `hdiutil verify`。按任务书保留 hdiutil。
3. 退出时若任务正处于「校验中」（ipatool 已完成、App 在读 IPA），下次恢复为暂停，继续时会重新执行一次 ipatool download（目标文件已存在时 ipatool 的行为未实测）。
4. 恢复的任务在 ipatool 打印出新的进度条之前，总大小来自上次保存的值；若上次从未拿到总大小，恢复后只显示「已暂停」，进度条为 0。
5. 写 `queue.json` 失败时静默忽略，下次队列变化再试；没有界面提示。
6. 「首次启动」判断只看标志：已经用 Homebrew ipatool 登录过的老用户，第一次打开也会显示未登录，需要再登录一次（这正是决定 ① 的预期行为：先看准备页再碰钥匙串）。
7. Debug / Release 运行时 macOS 把窗口状态写到 `$TMPDIR/app.ipadepot.mac.savedState`（因为用了 `-ApplePersistenceIgnoreState YES`），收工时已移入废纸篓；`~/Library/Preferences/app.ipadepot.mac.plist` 里的窗口位置照旧会更新（阶段二已知）。

## 待主会话决定

1. 失败的下载（非「需要许可」类）是否也要跨启动保存并恢复为暂停（已知问题 1）。改动很小：`persistableEntries` 放行 `.failed`，并排除 `licenseRequired`。
2. 本次新增的 Debug 冒烟入口：`SmokeDriver` 的 `-IPADepotSmokeMode`（`#if DEBUG`，Release 无此代码）。是否保留在仓库里。
3. `release.yml` 把 Release 建成**草稿**（`draft: true`），需要在 GitHub 页面手动点发布，以符合「用户亲自验收后再发」。若希望打标签即公开发布，删掉 `draft: true` 即可。
4. `release.yml` / `ci.yml` 用的是 `actions/checkout@v4` 与 `softprops/action-gh-release@v2` 大版本标签，没有固定到 commit SHA。
5. 关于页「许可」分组的布局（三行：IPA Depot / ipatool / 阿里妈妈数黑体）是本阶段新定的，原「开源组件」一行已并入其中。
6. 废纸篓里的本阶段清理目录 `~/.Trash/ipa-depot-test-cleanup-20261026-phase3/`（见下）是否清空，由主会话决定。

## 收工清理

- `build/` 只保留 `downloads/`（ipatool 官方包缓存，阶段一留下）与 `release/`；`DerivedData`、`smoke-data`、`smoke-downloads`、`smoke-shots`、`smoke-tools`、`tmp-phase3` 已逐项移入 `~/.Trash/ipa-depot-test-cleanup-20261026-phase3/`（按删除规则不用 rm）。
- 系统临时目录：`$TMPDIR/app.ipadepot.mac.savedState` 同样移入上述废纸篓目录；测试用的 `IPADepot*Tests-<UUID>` 临时目录由 tearDown 自删，收工时核对为 0 个。
- scratchpad 未写入文件。
