# 阶段八（下载按钮反馈与重复任务去重）进度

更新：2026-10-31 · 状态：**已完成，待主会话验收**（真实下载按红线未执行；未装机）

## 一、改动清单

### Core
| 文件 | 内容 |
|---|---|
| `Sources/IPADepotCore/DownloadTask.swift` | 新增 `DownloadDedupeKey`（appID + 外部版本 ID + 平台 + 账号；外部版本 ID / 平台的空字符串视为 nil，平台不区分大小写；`purchase` 与输出路径不参与）与 `matches(_:isCurrentAccount:)`（账号两边相同即匹配；一边为 nil = 当前账号时，另一边是当前账号才匹配；nil 对 nil 相等）；`DownloadRequest.dedupeKey` |
| `Sources/IPADepotCore/DownloadQueue.swift` | `DownloadItemStatus.isUnfinished`（排队 / 切换账号 / 下载中 / 停止中 / 校验中 / 已暂停）；`addDeduplicated(_:id:) -> (id: UUID, isNew: Bool)`：命中未结束的同一任务时不新建、不发布、不补位，返回已有 id；已请求取消（正在停止、马上移出队列）的不拦截；旧 `add(_:id:)` 签名不变，改为转调（返回新 id 或已有 id）；`unfinishedItemID(matching:)`。nil 账号的「当前账号」判断用已设置的 `DownloadAccountSwitching.isCurrentAccount`，未设置切换器时视为当前账号。并发语义（阶段七 `pump`）未改 |

### App
| 文件 | 内容 |
|---|---|
| `Logic/Services.swift` | `DownloadQueueing.addDeduplicated(_:id:)` |
| `Logic/DownloadsViewModel.swift` | `DownloadButtonPhase`（`idle` / `resolving` / `justAdded` / `inQueue`，`isEnabled` 只在 `idle` 为真）；`enqueue` 改走 `addDeduplicated`，命中去重时删除这次预留的 `contexts` / `outputs`（文件名不被占用），返回已有任务 id；`buttonPhase(for:accountID:)`：刚加入 > 已在队列 > 默认，「已在队列」由队列快照 `items` 实时推导（不靠点击记忆）；`justAdded`（键 → 令牌，`justAddedDuration` 默认 1.5 秒后清除，测试里调短）在入队前同步标记 |
| `Logic/AppModel.swift` | `pendingCatalogAction` 去掉 `@ObservationIgnored`（被观察，界面随之刷新）；`isResolving(_:)`（等账号匹配 / 自动切换 / 添加账号完成）；`downloadPhase(for:)`：搜索行按 appID + 平台 + 最新版 + 账号（普通结果 = 当前账号；公开目录结果 = 匹配地区的账号，没有该地区账号时为默认）推导 |
| `Views/DownloadPhaseButton.swift`（新） | 统一组件：默认原文案（可带图标）；解析中 = 小菊花 + 原文案、禁用；已加入 = `checkmark` + 「已加入」、禁用；已在队列 = `tray.full` + 「已在队列」、禁用；另有 `disabled` 参数承接原有的未登录禁用条件；悬停提示 |
| `Views/SearchView.swift` | 搜索结果行「下载最新版」「历史版本…」改用组件（「历史版本…」只有解析中 / 默认两态） |
| `Views/VersionsView.swift` | 三个入口改用组件：顶部「下载最新版」（externalVersionID = nil）、「领取免费许可并下载最新版…」（同最新版的键；点击仍是弹确认，确认后入队才有「已加入」）、版本行「下载」（按该行 externalVersionID） |
| `Views/SmokeDriver.swift` | Debug 冒烟模式 `p8Dedupe` |
| `Localizable.xcstrings` | 新增 5 个 key（共 266 个），全部有英文：已加入 / Added、已在队列 / In Queue、已加入下载队列、下载页里已有这个任务…、正在匹配该地区的账号… |

### 既有测试的适配（语义变化所致）
旧的队列测试用同一个 appID、只靠文件名区分任务，阶段八起会被去重。改为：`TestSupport.swift` 新增 `testAppID(name)`（按名字算稳定的 appID），Phase2 / 3 / 4 / 5 / 7 Core 测试的 `request(_:)` 助手改用它；App 测试里两处「同名文件避让」改为同版本号标签、不同外部版本 ID 的任务（`ViewModelTests.testEnqueueNamesFilesAndAvoidsCollisions`、`Phase3ViewModelTests` 恢复任务后的同名新任务）；`Phase7ViewModelTests` 三个任务给不同 App id。断言本身未放宽。

## 二、测试

```
xcodegen generate                                                          → OK
xcodebuild build -scheme IPADepot -configuration Debug … -derivedDataPath build/DerivedData → BUILD SUCCEEDED（无源码告警）
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData    → TEST SUCCEEDED（连跑 3 次均 0 失败）
xcodebuild test -scheme IPADepot -derivedDataPath build/DerivedData        → TEST SUCCEEDED
  （两个 scheme 都会跑两个测试包）
  IPADepotCoreTests  Executed 142 tests, 3 skipped（真机冒烟，默认跳过）, 0 failures  （原 134 + 新 8）
  IPADepotTests      Executed 67 tests, 0 failures                                   （原 61 + 新 6）
  合计 209（原 195 + 新增 14），0 失败
python3 -I scripts/sync-strings.py --translations <英文 json>              → 共 266 个 key，新增 5，缺英文 0
python3 -I scripts/sync-strings.py --check                                 → exit 0
```

新增 `Tests/IPADepotCoreTests/Phase8CoreTests.swift`（8）：键的规范化（空字符串 = nil、平台大小写、输出与 purchase 不参与）；nil 账号 = 当前账号的匹配规则；同键返回已有 id 且 `isNew = false`、旧 `add` 同样去重、不创建下载任务；appID / 版本 / 平台 / 账号任一不同都新建；已完成 / 失败 / 取消的不拦截；已请求取消（停止中）的不拦截；排队中 / 下载中 / 已暂停 / 排队中被暂停 / 切换账号中都拦截；恢复的暂停旧任务（无账号）拦截当前账号的同一任务、不拦截其他账号。
新增 `Tests/IPADepotTests/Phase8ViewModelTests.swift`（6）：无任务 → 默认；入队后立刻「已加入」→ 约定时长后「已在队列」→ 完成后默认；暂停仍「已在队列」、失败与取消恢复默认；三个并发入队只建一条任务、返回同一 id、预留文件名被释放（下一个同标签任务是 `(2)` 而不是 `(4)`）；历史版本页按 externalVersionID 匹配（其他版本、最新版、平台不同、账号不同均为默认）；公开目录结果自动切换账号期间「下载最新版」为解析中（只影响被点的按钮和那一行）、切换完成后「已加入 / 已在队列」，「历史版本…」切换期间解析中、完成后恢复；有下载进行中时公开目录任务直接绑定匹配地区账号，按该账号推导「已在队列」、日本区同 App 不受影响、再次入队不重复。

## 三、Debug 冒烟（`docs/screenshots/phase8/`）

运行方式：Debug 包，**直接运行** `build/DerivedData/Build/Products/Debug/IPA Depot.app/Contents/MacOS/IPA Depot`（未用 `open`），环境变量 `CFFIXED_USER_HOME=build/smoke-p8-home`、`IPADEPOT_DATA_ROOT=build/smoke-p8-data`、`IPADEPOT_IPATOOL_PATH=build/smoke-tools/fake-ipatool-p8`（假脚本，源码 `docs/screenshots/phase8/fake-ipatool.sh`，与阶段七脚本相同，只改了注释），参数 `-IPADepotSmokeOutput build/smoke-p8-shots -IPADepotSmokeMode p8Dedupe -hasCompletedFirstLogin NO -downloadDirectory build/smoke-p8-downloads -ApplePersistenceIgnoreState YES`。账号为 `jp@example.test` 假账号；**真实 ipatool 未被冒烟调用**；未读写钥匙串，未碰 `~/.ipatool`。App 跑完自行退出（PID 43948，约 17 秒），之后无残留 Debug / 假 ipatool 进程，`$TMPDIR` 无 `app.ipadepot.mac.savedState` 残留。截图用 App 渲染自己窗口的方式（同前几期），未申请屏幕控制权限。

| 步骤 | 结果（摘自 `smoke-log.txt`） | 截图 |
|---|---|---|
| 搜索（假 ipatool 返回 2 个日本区 App），第一行点「下载最新版」 | `マンガ図書館=justAdded`，第二行 `idle`；按钮为灰色带勾「已加入」 | `p8-01-search-just-added.png` |
| 约 1.5 秒后 | `マンガ図書館=inQueue`，`queue=1`；按钮为禁用的「已在队列」 | `p8-02-search-in-queue-disabled.png` |
| 取消后第一行恢复 `idle`；第二行连点三次（三个并发入队） | `items=1`，下载页只有一条「乗換案内（日本区）」正在下载，文件名 `乗換案内（日本区）_12.1.ipa`（无序号） | `p8-03-triple-click-one-task.png` |
| 进入第二行的历史版本页，下载版本 880000002 | 点击后 `880000002=justAdded`，之后 `latest=inQueue`、`880000002=inQueue`、880000003 / 880000001 `idle`；顶部「下载最新版」与 3.8.2 行均为禁用的「已在队列」 | `p8-04-versions-in-queue-disabled.png` |
| 取消全部 | `items=0`，各行恢复 `idle` | — |

`fake-ipatool-calls.log`：`download -i 1001` 一次；连点三次后 `download -i 1002` 只有**一次**（pid 44033）；版本 880000002 的任务因同时下载数 1 在排队，未启动。

## 四、Release 产物（`build/release/`，0.2.0 / CFBundleVersion 202610301914）

| 文件 | 大小（字节） | sha256 |
|---|---|---|
| `IPA-Depot-0.2.0-macos-universal.zip` | 41,634,436 | `（以 build/release/*.sha256 为准，主会话小修后重打）` |
| `IPA-Depot-0.2.0-macos-universal.dmg` | 46,449,740 | `（以 build/release/*.sha256 为准，主会话小修后重打）` |
| `*.zip.sha256` / `*.dmg.sha256` | 102 / 102 | — |
| `IPA Depot.app` | — | 本地验收用，不上传 |

核对：`shasum -a 256 -c` 两个 OK；`hdiutil verify` VALID；主程序、`Resources/bin/ipatool`、`IPADepotCore.framework` 均 `x86_64 arm64`；`codesign --verify --deep --strict` 通过，`Signature=adhoc`、flags `0x2(adhoc)`；`CFBundleShortVersionString=0.2.0`、`LSMinimumSystemVersion=14.0`；主程序 `strings | grep IPADepotSmoke` = 0，Core `strings | grep FileCredentialVault` = 0；内置 ipatool `--version` = 2.7.0（只查版本；`~/.ipatool` 仍不存在，`~/Library/Caches/ipatool` mtime 前后不变）。旧 `build/release/` 已整体移到 `~/.Trash/ipa-depot-release-0.2.0-pre-20261031-c/release`。**未装机，未碰 /Applications。**

## 五、已知问题

1. **「最新版」与「指定版本」是不同的键**：搜索页 / 历史版本页顶部的「下载最新版」（externalVersionID = nil）与历史版本列表里标「最新」那一行的「下载」（具体 ID）互不去重，同一个版本可能各下一份（文件名会加序号）。按设计的键定义如此；若要合并需要知道最新版的外部 ID（搜索结果没有）。
2. **`purchase` 不在键里**：已有未结束的普通任务时，「领取免费许可并下载」会命中去重而不再新建带 `--purchase` 的任务（确认弹窗关闭后按钮显示「已在队列」）。实际只在许可失败（失败的任务不拦截）后才会走领取，正常路径不受影响。
3. 「已加入」只在本次入队时显示；若同一任务已在队列（例如另一页面已加入），点不到按钮（已禁用），符合设计。
4. 沿用：跨账号任务可能久等（阶段七已接受）；`hdiutil create` 弃用提示。

## 六、待主会话决定

1. Debug 冒烟模式 `p8Dedupe` 是否保留（默认保留，与前几期一致）。
2. 已知问题 1 是否需要把「最新版」与列表中最新那一行视为同一任务（需要在版本列表加载后建立 nil ↔ 最新 ID 的映射，会让去重键依赖页面状态，未自行实现）。
3. 提交署名按任务书写 `Co-Authored-By: Claude Fable 5.1`（实际执行模型为 Opus 5.5）。

## 七、收工清理

逐项移入 `~/.Trash/ipa-depot-test-cleanup-20261031-phase8/`（未用 rm、未用通配符）：`build/DerivedData`、`build/smoke-p8-data`、`build/smoke-p8-downloads`、`build/smoke-p8-home`、`build/smoke-p8-shots`、`build/smoke-p8-stdout.log`、`build/smoke-p8.pid`、`build/smoke-tools`（假 ipatool 运行副本与其 state）、`build/release-build.log`、scratchpad 的 `phase8/`（构建 / 测试日志、英文译文 json）。另有前两轮测试中途崩溃（旧测试未适配去重时 `factory[1]` 越界）留在 `$TMPDIR` 的 14 个 `IPADepotCoreTests-*` / `IPADepotTests-*` 临时目录（02:56–03:01 生成），逐个按全名移入同一废纸篓目录的 `tmpdir-test-residue/`；现 `$TMPDIR` 下无 `IPADepot*` 残留。`build/` 只剩 `downloads/` 与 `release/`。假 ipatool 脚本源码保留在 `docs/screenshots/phase8/fake-ipatool.sh`。
