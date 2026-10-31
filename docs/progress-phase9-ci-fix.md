# 阶段九（CI 构建失败修复：类型检查超时）进度

更新：2026-10-31 · 状态：**已完成，待主会话验收**（纯重构；未装机，未 push）

## 一、问题

GitHub Actions（`macos-15`，Xcode 16.x）的 Debug 构建失败：

```
App/Views/ContentView.swift:8:25: error: the compiler is unable to type-check this expression in reasonable time;
try breaking up the expression into distinct sub-expressions
```

本机 Xcode 27.1 能编过，因此「本地能编译」不能作为验收依据。

## 二、根因

`ContentView.body` 把 `NavigationSplitView` 后面的 3 个 `.sheet(isPresented:)`、2 个 `.sheet(item:)`、4 个 `.alert`、3 个 `.errorAlert`、`.overlay`、`.animation`、`.task` 串成**一条**表达式，其中 8 处 `Binding(get:set:)` 直接内联在修饰符参数里、alert 的标题又是 `?? ""` / `map` 组合。整条链的泛型 `ModifiedContent` 嵌套与闭包参数类型都要由类型检查器一次性推断，Xcode 27.1 本机实测要 **8.4 秒**，旧版编译器直接触发超时报错。

## 三、拆分方案

### ContentView（`App/Views/ContentView.swift`）
`body` 只保留 `NavigationSplitView` + 4 个 `.modifier(...)` + 原样的 `.task`（含 `#if DEBUG` 的 `SmokeDriver.runIfRequested`）。sheet / alert 按**原顺序**拆进 4 个 `private struct …: ViewModifier`，每个自己 `@Environment(AppModel.self)` 取模型，Binding 全部改成带显式类型的私有计算属性，闭包参数写明类型：

| 顺序 | ViewModifier | 负责（与原链顺序一致） | 私有绑定 / 辅助 |
|---|---|---|---|
| 1 | `LoginPresentations` | 登录 sheet | `isShowingLogin: Binding<Bool>` |
| 2 | `LicensePresentations` | 下载许可 alert（领取并下载 / 付费须购买） | `prompt`、`title: String`、`isPresented: Binding<Bool>`、`actions(for:)`、`message(for:)` |
| 3 | `AccountPresentations` | 切换遮罩 `.overlay` + `.animation` → 账号管理 sheet → 补密码 sheet → 补地区 sheet → 切换失败 alert → 缺少地区账号 alert | `isShowingManager`、`passwordPrompt: Binding<AccountPasswordPrompt?>`、`regionPrompt: Binding<AccountRecord?>`、`failureTitle`、`isShowingFailure`、`missingRegionTitle`、`isShowingMissingRegion`、`failureMessage(_:)` |
| 4 | `ErrorPresentations` | `errorAlert`×3（暂时无法继续 / 登出失败 / 无法开始下载）→ 找不到 ipatool alert | `catalogActionError` / `logoutError`（`Bindable(model).…`，与原 `$model.…` 同一种绑定）、`enqueueError: Binding<ErrorPresentation?>`；`@Binding showingSetupError` 由 ContentView 的 `@State` 传入 |

### 其他文件（基线里冒出或贴近 100 ms 的，一并按同样手法拆）
| 文件 | 拆法 |
|---|---|
| `App/Views/SettingsView.swift` | `Form` 的 6 个分区拆成 `accountSection` / `downloadSection` / `cacheSection` / `aboutSection` / `licenseSection` / `updateSection` 计算属性；「同时下载数」Picker 的内联 `Binding(get:set:)` 改为 `maxConcurrentDownloads: Binding<Int>` |
| `App/Views/SmokeDriver.swift`（仅 Debug） | `runIfRequested` 的默认冒烟流程拆成 `captureLaunchAndLogin` / `captureSearchAndVersions` / `capturePages` 三个私有静态函数，语句与顺序不变，`note("done")` 与退出仍在 `runIfRequested` 末尾 |
| `App/Views/DownloadsView.swift` | `body` 拆出 `emptyState` / `activeSection` / `completedSection`（基线 87 ms，未超但余量小） |
| `App/Views/AccountViews.swift` | `AccountMenuItems.body` 拆出 `otherAccountsSection`（基线 86 ms） |
| `App/Views/VersionsView.swift` | `header` 拆出 `appMetadata`（Bundle ID · ID · 当前版本 · 价格那一行；基线 76 ms） |

文案字符串一个字未改：构建后从 `*.stringsdata` 抽出的 Localizable key 集合与改动前**逐行 diff 完全一致（266 个）**；`python3 -I scripts/sync-strings.py --check` 返回 0，`Localizable.xcstrings` 无改动。

## 四、类型检查耗时（本机 Xcode 27.1，Debug，全量编译 87 个 Swift 文件）

命令：
```
xcodebuild -scheme IPADepot -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS' \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -warn-long-expression-type-checking=100 -Xfrontend -warn-long-function-bodies=100' build
```
（App 目标依赖 IPADepotCore，同一次构建两者都会编译，所以告警列表覆盖两个目标。）

### 阈值 100 ms
| 位置 | 改前 | 改后 |
|---|---|---|
| `ContentView.swift:8:25` getter `body` | **8379 ms** | 无告警 |
| `ContentView.swift:81:13` 表达式（整条修饰符链） | **8263 ms** | 无告警 |
| `SettingsView.swift:9:25` getter `body` | 109 ms（另一次 102 ms） | 无告警 |
| `SmokeDriver.swift:13:17` `runIfRequested` | 134 ms（另一次 128 ms） | 无告警 |
| 合计 | 4 条 | **0 条**（连续两次全量构建均为 0；IPADepotCore 改前改后均为 0） |

### 余量探针（函数体阈值 50 ms / 表达式阈值 30 ms，改后全量构建）
| 位置 | 耗时 |
|---|---|
| `DownloadsView.swift:7` getter `body` | 77 ms |
| `VersionsView.swift:21` getter `header` | 75 ms |
| `AppModel.swift:51` `init(services:)` | 74 ms（未改：初始化顺序敏感，且远低于 100） |
| `SmokeDriver.swift:64` `captureSearchAndVersions` | 63 ms |
| `LoginSheet.swift:177` getter `body` | 59 ms |
| `SmokeDriver.swift` `runPhase3` | 54 ms |
| 单个表达式最长 | 37 ms（`AccountViews.swift:43`） |

改后 ContentView 里最慢的单个表达式约 18–20 ms（改前那条链 8263 ms）。

## 五、测试

```
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData -destination 'platform=macOS' → TEST SUCCEEDED
xcodebuild test -scheme IPADepot     -derivedDataPath build/DerivedData -destination 'platform=macOS' → TEST SUCCEEDED
  IPADepotCoreTests  Executed 142 tests, 3 skipped（真机冒烟，默认跳过）, 0 failures
  IPADepotTests      Executed 67 tests, 0 failures
  合计 209，0 失败（两个 scheme 都会跑这两个测试包，结果一致）
python3 -I scripts/sync-strings.py --check → 0
```

## 六、Release 产物（`build/release/`，0.2.0 / CFBundleVersion 202610310518）

| 文件 | 大小（字节） | sha256 |
|---|---|---|
| `IPA-Depot-0.2.0-macos-universal.zip` | 41,632,594 | `8d654fc517114595b168b7e76da2c80d6da9f0c76110eb1bc43319909bef5b95` |
| `IPA-Depot-0.2.0-macos-universal.dmg` | 46,460,647 | `944bfdcbde57cceb539bc0eaeb8e545d99a0bf8ee94681f7e465c349877bb939` |
| `*.zip.sha256` / `*.dmg.sha256` | 102 / 102 | — |
| `IPA Depot.app` | — | 本地验收用，不上传 |

核对：`shasum -a 256 -c` 两个 OK；`hdiutil verify` VALID；主程序、`Resources/bin/ipatool`、`IPADepotCore.framework` 均 `x86_64 arm64`；`codesign --verify --deep --strict` 通过（valid on disk / satisfies its Designated Requirement），`Signature=adhoc`、flags `0x2(adhoc)`；`CFBundleShortVersionString=0.2.0`、`LSMinimumSystemVersion=14.0`；主程序 `strings | grep IPADepotSmoke` = 0，Core `strings | grep FileCredentialVault` = 0；内置 ipatool sha256 与上一版产物里的一致（`d0d905be…`，ad-hoc 深度签名后的值；`vendor/ipatool` 未改动）。旧 `build/release/` 已整体移到 `~/.Trash/ipa-depot-release-0.2.0-pre-20261031-e/release`。**未装机，未碰 /Applications。**

## 七、已知问题 / 说明

1. 耗时均为本机 Xcode 27.1 数据；Xcode 16 的类型检查器更慢，绝对值会更高。CI 报错的是单条表达式超时，改后单条表达式最长 37 ms、ContentView 不再有长链，预期不会再触发；最终以推送后 CI 结果为准。
2. CHANGELOG 未改（纯重构，无用户可见变化）。

## 八、待主会话决定

1. 是否推送触发 CI 复核（本阶段按红线未 push）。
2. 是否在 `ci.yml` 的 Debug 构建步骤加 `-warn-long-expression-type-checking=… -warn-long-function-bodies=…`（作为告警，或配合 `-warnings-as-errors` 作硬门槛），防止以后再长出长表达式。本阶段按红线未动 CI 文件。
