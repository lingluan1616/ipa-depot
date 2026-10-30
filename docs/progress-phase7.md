# 阶段七（同时下载数）进度

更新：2026-10-31 · 状态：**已完成，待主会话验收**（真实下载按红线未执行；未装机）

## 一、ipatool v2.7.0 核实：`download` 会不会回写 cookies 文件

**结论：会。** 但不是「结束时」写，而是在下载流程**前段**每发一次 Apple 接口请求就写一次；IPA 本体传输阶段不写。写入有文件锁并先合并磁盘内容，同账号并发属于同内容覆盖，可接受。按设计第 4 条，README 常见问题已注明「同时下载只对同一个账号生效」。

源码依据（GitHub `majd/ipatool` tag `v2.7.0`，用 `gh api repos/majd/ipatool/contents/<path>?ref=v2.7.0` 读取）：

| 位置 | 内容 |
|---|---|
| `cmd/common.go` · `newCookieJar(stateDirectory)` | Cookie jar = `github.com/juju/persistent-cookiejar`（`go.mod`：v1.0.0），文件为 `<state>/cookies`（`cmd/constants.go`：`CookieJarFileName = "cookies"`）；`initWithCommand` 为每条命令创建 |
| `pkg/http/client.go` · `(*client[R]).Send` | 每次请求 `client.Do(request)` 之后**无条件** `c.cookieJar.Save()`，失败则报 `failed to save cookies` |
| `pkg/appstore/appstore_download.go` · `(*appstore).Download` | 先 `t.sendDownloadProduct(...)`，再 `t.downloadFile(...)` 下载 IPA |
| `pkg/appstore/appstore_download_product.go` · `sendDownloadProduct` / `sendUpdateProduct` | 走 `t.downloadClient.Send(...)`（第 71、113、149 行）→ 触发 `Save()` |
| `pkg/appstore/appstore_download.go` · `downloadFile` | 用 `t.httpClient.Do(req)`（第 270 行），**不经过 `Send`，不写 Cookie** |
| `juju/persistent-cookiejar` v1.0.0 `serialize.go` · `(*Jar).save` | 先取文件锁 `cookies.lock`（`lockFile(lockFileName(j.filename))`），再读磁盘上的 Cookie `mergeFrom` 合并，最后写回 |

因此：同账号 N 个下载同时启动时，会在前几秒各写一次 `cookies`，写入由文件锁串行化且先合并，内容都是同一账号的同一会话，不会互相破坏。跨账号并发会让两个账号的 Cookie 混进同一文件——本实现不允许跨账号并发（见下）。

## 二、改动清单

### Core（`Sources/IPADepotCore/DownloadQueue.swift`）
- `runningID: UUID?` → `runningIDs: [UUID]`（按开始顺序；包含运行中 / 停止中 / 校验中 / 正在为它切换账号的任务）；`maxConcurrent`（默认 1）。
- 公开接口：`setMaxConcurrent(_ n: Int)`（钳到 `DownloadQueue.concurrencyRange` = 1...3，调大立即补位）、`maxConcurrentDownloads`、`activeItemIDs`；`activeItemID` 保留（= 最早开始的那条，兼容旧调用与旧测试）。
- `pump()` 改为循环补位：
  1. 有条目在切换账号 → 不补位；
  2. 没有任何任务在运行 → 先进先出取队首；队首属于其他账号则先切换（与单槽位时代一致）；
  3. 已有任务在运行 → 只取「不需要切换账号」的排队任务（属于当前账号或无账号旧任务），仍按先进先出；
  4. 达到上限或无可启动项即停。
- `afterSwitch` 成功启动后再 `pump()`（按新账号补位）；各失败 / 暂停 / 取消分支释放槽位后 `pump()`。
- 调小上限不打断任何任务（不发 pause / cancel），只是 `pump` 条件不满足而不补位。
- `RunningTaskBox` 改为 `[UUID: DownloadTasking]`：`insert(_:for:)` / `remove(_:)` / `count` / `shutDown() -> [DownloadTasking]`；`terminateRunningTasks()` 对全部运行中任务 `pause()`（`.tmp` 保留续传），之后不再启动任何任务。
- `pause / resume / cancel / remove / restore` 语义不变（`cancel` / `remove` 的「是否运行中」改为查集合）。
- 进度不串台：每个任务的事件经各自的 `AsyncStream` 回到 actor，`handle(_:for:)` 按 id 更新对应条目（`DownloadTask` 各自解析自己进程的输出）；新增测试覆盖。

### App
| 文件 | 内容 |
|---|---|
| `Logic/Services.swift` | `DownloadQueueing.setMaxConcurrent(_:)`；`KeyValueStoring.integer(forKey:)`（`UserDefaults` 自带；测试替身 `MemoryDefaults` 同步补） |
| `Logic/SettingsViewModel.swift` | `maxConcurrentDownloadsKey = "maxConcurrentDownloads"`、`maxConcurrentDownloadsOptions = [1, 2, 3]`、`maxConcurrentDownloads`（启动读 UserDefaults，未设置 / 异常值按 1，超过 3 按 3）、`setMaxConcurrentDownloads(_:)`（持久化 + `onMaxConcurrentDownloadsChanged` 回调，值不变不回调） |
| `Logic/AppModel.swift` | 回调接到 `services.queue.setMaxConcurrent`（执行时读最新值，连续切换以最后一次为准）；`bootstrap` 在开始观察队列前把保存的值设给队列 |
| `Logic/DownloadsViewModel.swift` | `activeRows`：正在下载 / 校验 / 切换账号的排前面，其余（排队 / 暂停 / 失败）保持队列顺序；`runningCount` |
| `Views/SettingsView.swift` | 「下载」一节加「同时下载数」分段选择 1 / 2 / 3 + 说明（同账号生效、调小不打断） |
| `Views/DownloadsView.swift` | 「进行中」分组标题右侧「正在下载 N / 同时 M 个」；空态文案改为「任务按加入顺序进行，同时下载数可在设置中调整（1～3 个）」 |
| `Views/SmokeDriver.swift` | Debug 冒烟模式 `p7Concurrent`（结束时若原本没有 `maxConcurrentDownloads` 偏好则删除） |
| `Localizable.xcstrings` | 新增 5 个 key（共 261 个），全部有英文；旧空态文案标记 stale |

### 文档
`README.md`：功能列表「下载队列」「设置」、使用说明「设置」各加一句；常见问题新增「同时下载数设成 3，为什么有的任务还在排队」（同账号生效 + Cookie 文件加锁合并）；English 段同步。`CHANGELOG.md` 0.2.0 补「同时下载数」。版本仍为 0.2.0。

## 三、测试

```
xcodegen generate                                                          → OK
xcodebuild build -scheme IPADepot -configuration Debug … -derivedDataPath build/DerivedData → BUILD SUCCEEDED（无源码告警）
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData    → TEST SUCCEEDED（连跑 3 次均 0 失败）
  IPADepotCoreTests  Executed 134 tests, 3 skipped（真机冒烟，默认跳过）, 0 failures  （原 120 + 新 14）
xcodebuild test -scheme IPADepot -derivedDataPath build/DerivedData        → TEST SUCCEEDED
  IPADepotTests      Executed 61 tests, 0 failures                                   （原 57 + 新 4）
  合计 195（原 177 + 新增 18），0 失败
python3 -I scripts/sync-strings.py --translations <英文 json>              → 共 261 个 key，新增 5，缺英文 0
python3 -I scripts/sync-strings.py --check                                 → exit 0
```

新增 `Tests/IPADepotCoreTests/Phase7CoreTests.swift`（14）：默认 1 与钳制；上限 1 与单槽位一致（逐个运行、`activeItemID` 兼容）；上限 1 时队首为其他账号仍先切换；调大立即补位；上限 3 同账号三条同时 running、第四条排队、空出后补位、不切换；两条并发进度 / 日志不串台；跨账号任务等当前账号全部结束才切换；切换期间不补位（同新账号、旧账号、无账号任务都不启动）且切换后按新账号补位、旧账号任务继续排队；运行中 3→1 不打断（cancelCount 全 0）、结束两条仍不补位、全部结束才补 1 条；暂停一条其余继续并补位、取消一条（删 `.tmp`）其余继续并补位、继续已暂停的在满槽时排队；运行中的第二条也不能 `remove`；恢复的任务继续时按上限启动；退出终止全部三条（按暂停，不是取消）、不补位、退出后不再启动；`RunningTaskBox` 多任务。
新增 `Tests/IPADepotTests/Phase7ViewModelTests.swift`（4）：默认 1、选择持久化与读回、值不变不重复回调；存储异常值钳制（7→3、-1→1、非数字→1）；`bootstrap` 把保存的值设给队列、设置改动到达队列；下载页进行中的排前面、暂停的排后面。

## 四、Debug 冒烟（`docs/screenshots/phase7/`）

运行方式：Debug 包，**直接运行** `build/DerivedData/Build/Products/Debug/IPA Depot.app/Contents/MacOS/IPA Depot`（未用 `open`），环境变量 `CFFIXED_USER_HOME=build/smoke-p7-home`、`IPADEPOT_DATA_ROOT=build/smoke-p7-data`、`IPADEPOT_IPATOOL_PATH=build/smoke-tools/fake-ipatool-p7`（假脚本，源码 `fake-ipatool.sh`：阶段六脚本 + download 改为慢速假进度，每 0.5 秒输出一行 `downloading NN% |…| (x/y MB, z MB/s)`，各任务大小 / 速度按 App id 不同，`.tmp` 每步只追加 100 KB，进度走完后以短 sleep 循环等待暂停 / 取消），参数 `-IPADepotSmokeOutput build/smoke-p7-shots -IPADepotSmokeMode p7Concurrent -hasCompletedFirstLogin NO -downloadDirectory build/smoke-p7-downloads -ApplePersistenceIgnoreState YES`。账号均为 `@example.test` 假账号；**真实 ipatool 未被冒烟调用**；Debug 冒烟用文件保险库，未读写钥匙串，未碰 `~/.ipatool`。App 跑完自行退出（`NSApp.terminate`），运行约 25 秒。

| 步骤 | 结果（摘自 `smoke-log.txt`） | 截图 |
|---|---|---|
| 添加日本假账号，设置页把「同时下载数」选为 3 | 分段选择显示 1 / 2 / 3，选中 3；下方说明文字 | `p7-01-settings-concurrency.png` |
| 上限 3，加入四个任务 | `running=3`：Alpha / Beta / Gamma「正在下载」各自进度、大小、速度不同，Delta「排队中」；标题「正在下载 3 / 同时 3 个」 | `p7-02-limit3-three-running.png` |
| 运行中调到 1 | 仍 `running=3`（不打断）；随后取消三条时 Delta 也未被补位（取消前运行数仍 ≥ 1） | — |
| 上限 1，重新加入三个任务 | `running=1`：Echo「正在下载」，Foxtrot / Golf「排队中」 | `p7-03-limit1-one-running.png` |
| 上限 3，添加美国假账号（2FA 123456，当前变为美国），加入 美国 / 日本 / 美国 三个任务 | `running=2`：两条美国同时下载，日本任务排队（排在进行中的后面）；未发生账号切换 | `p7-04-mixed-accounts-same-account-only.png` |

`fake-ipatool-calls.log`：7001 / 7002 / 7003 同一秒内以 `jp@example.test` 启动（三个不同 pid），7004 从未启动；上限 1 时只有 7011 启动；混排时只有 7021 / 7023 以 `us@example.test` 启动，7022（日本）未启动、无 `auth revoke`（除添加美国账号时的正常换入）。冒烟结束后无残留 Debug / 假 ipatool 进程；真实偏好 `defaults read app.ipadepot.mac maxConcurrentDownloads` 冒烟前后均不存在。截图用 App 自己渲染自己窗口的方式（同前几期，`CGWindowListCreateImage` 只取本窗口），未申请屏幕控制权限。

## 五、Release 产物（`build/release/`，0.2.0 / CFBundleVersion 202610301841）

| 文件 | 大小（字节） | sha256 |
|---|---|---|
| `IPA-Depot-0.2.0-macos-universal.zip` | 41,593,982 | `22a22095e0e404114988da01e6c60084e703cdb32902bc0f7f29c26c81685045` |
| `IPA-Depot-0.2.0-macos-universal.dmg` | 46,423,269 | `daa3644ba9c4f0cf87be65b16e6ce14abc510c21c85274a4bc32b038f6ebec03` |
| `*.zip.sha256` / `*.dmg.sha256` | 102 / 102 | — |
| `IPA Depot.app` | — | 本地验收用，不上传 |

核对：`shasum -a 256 -c` 两个 OK；`hdiutil verify` VALID；主程序、`Resources/bin/ipatool`、`IPADepotCore.framework` 均 `x86_64 arm64`；`codesign --verify --deep --strict` 通过，`Signature=adhoc`、flags `0x2(adhoc)`；`CFBundleShortVersionString=0.2.0`、`LSMinimumSystemVersion=14.0`；主程序 `strings | grep IPADepotSmoke` = 0，Core `strings | grep FileCredentialVault` = 0；内置 ipatool `--version` = 2.7.0（只查版本，未建 `~/.ipatool`，`~/Library/Caches/ipatool` mtime 未变）。旧 `build/release/` 已整体移到 `~/.Trash/ipa-depot-release-0.2.0-pre-20261031-b/release`。**未装机，未碰 /Applications。** Release 启动冒烟本期未做（任务书未要求；用户正在用同 Bundle ID 的正式版）。

## 六、已知问题

1. **跨账号任务可能久等**：已有当前账号的任务在跑时，补位总是优先当前账号的排队任务；如果用户不断加入当前账号的任务，属于其他账号的任务会一直等（按设计「补位优先当前账号」）。上限 1 时不受影响（严格先进先出）。
2. 排队中的跨账号任务状态文字仍是「排队中」，没有单独提示「等当前账号的任务完成后切换」（任务书要求排队中的保持原样）。
3. 同账号并发对 Apple 服务器的影响（限速 / 风控）未实测（红线：不做真实下载），需用户实测 2、3 个同时下载的速度与稳定性。
4. 沿用：`hdiutil create` 弃用提示。

## 七、待主会话决定

1. **提交署名**：任务书要求 `Co-Authored-By: Claude Fable 5.1`，本次两个提交按会话的署名要求写为 `Claude Opus 5.5`（实际执行模型，与阶段六一致）。如需统一请主会话改写（本地未 push）。
2. 已知问题 1 是否需要防饥饿（例如队首是跨账号任务时停止补位，等当前账号任务跑完就切换）？会让「补位优先当前账号」变弱，未自行实现。
3. Debug 冒烟模式 `p7Concurrent` 是否保留（默认保留，与前几期一致）。

## 八、收工清理

逐项移入 `~/.Trash/ipa-depot-test-cleanup-20261031-phase7/`（未用 rm、未用通配符）：`build/DerivedData`、`build/smoke-p7-data`、`build/smoke-p7-downloads`、`build/smoke-p7-home`、`build/smoke-p7-shots`、`build/smoke-p7-stdout.log`、`build/smoke-p7.pid`、`build/smoke-tools`（假 ipatool 运行副本与其 state）、`build/release-build.log`、scratchpad 的 `phase7/`（构建 / 测试日志、英文译文 json、假下载探针 `fakeprobe/`）。`$TMPDIR` 下无 `app.ipadepot.mac.savedState` 与 `IPADepot*` 残留；无残留 Debug / 假 ipatool 进程。`build/` 只剩 `downloads/` 与 `release/`。假 ipatool 脚本源码保留在 `docs/screenshots/phase7/fake-ipatool.sh`。
