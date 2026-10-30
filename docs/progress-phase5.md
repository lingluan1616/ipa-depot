# 阶段五（多账号与地区切换）进度

更新：2026-10-30 · 状态：**已完成，待主会话验收**（真实账号切换按红线未执行，需用户验收）

## 一、ipatool v2.7.0 行为核实（源码，tag v2.7.0；依赖 juju/persistent-cookiejar v1.0.0）

来源：`https://raw.githubusercontent.com/majd/ipatool/v2.7.0/<文件>` 与 `codeload.github.com/majd/ipatool/tar.gz/refs/tags/v2.7.0` 全量源码 grep；`go.mod` 第 12 行锁定 `github.com/juju/persistent-cookiejar v1.0.0`。

| 问题 | 结论 | 依据（文件:行） | 核实状态 |
|---|---|---|---|
| Cookie 文件名与位置 | `<状态目录>/cookies`，常量 `ConfigDirectoryName=".ipatool"`、`CookieJarFileName="cookies"` | `cmd/constants.go:4-6`；`cmd/common.go:55-59`（`Filename: filepath.Join(stateDirectory, CookieJarFileName)`） | 已核实 |
| Cookie 格式 | persistent-cookiejar 的 JSON 数组（只写 Persistent 的条目），旁边有 `cookies.lock` 文件锁，文件权限 0600 | juju `serialize.go:123-147`（`writeTo` / `allPersistentEntries`）、`:49`（`OpenFile(..., 0600)`）、`:151-153`（`.lock`） | 已核实 |
| 状态目录选择顺序 | 先取绝对路径的 `XDG_STATE_HOME`，其次 `XDG_DATA_HOME`，得到 `<它>/ipatool`；**`~/.ipatool` 存在时**：若新目录已存在或在旧目录之内 → 用 `~/.ipatool`；若新目录不存在 → **把 `~/.ipatool` 整体 rename 成新目录**并用新目录（rename 失败才退回旧目录）；`~/.ipatool` 不存在 → 建新目录（0700） | `cmd/state_directory.go:12-61`（`:16-22` 选变量，`:35-42` 返回旧目录，`:44-53` 迁移，`:56-60` 新建） | 已核实 |
| 每条命令都会加载 Cookie | 所有子命令初始化时都 `prepareStateDirectory` 并 `cookiejar.New`（New 时 `load()` 读入磁盘 Cookie） | `cmd/common.go:110-112`；juju `jar.go:99`、`:118` | 已核实 |
| `auth login` 写 Cookie 是重写还是追加 | **合并**：每个 HTTP 请求后 `cookieJar.Save()`；Save 先加锁、读回磁盘上的 Cookie 合并进内存（按 `Updated` 取新），删过期，再截断整体写回。因此登录前磁盘上残留的旧账号 Cookie 会被合并进新会话 | `pkg/http/client.go:188`；juju `serialize.go:22-30`（注释原文 "reads any cookies that have been stored from it and merges them"）、`:43-71`、`jar.go:367-382` | 已核实 |
| `auth revoke` 删除什么 | 只删钥匙串 `account` 条目与 `kbsync-v1` 条目（并清内存 kbsync 缓存）；**不碰 Cookie 文件**、不发网络请求（因此也不触发 Save） | `pkg/appstore/appstore_revoke.go:11-30`（`:12` Remove("account")，`:20-22` kbsync）；`cmd/auth.go:144-158` | 已核实 |
| ipatool 是否有任何删除 Cookie 的代码 | 没有：全量源码 grep `RemoveAll` / `cookieJar.` 只有 `client.go:188` 的 Save | grep 结果见上 | 已核实 |
| 登录成功写什么 | 钥匙串 `account` 条目（整个 Account 结构，含明文密码、StoreFront），`keychain.Set` 覆盖同一槽位 | `pkg/appstore/appstore_login.go:146`（`login`）、`:213-226`（组装 Account 并 `Set("account")`） | 已核实 |
| 2FA | 交互模式提示 `enter 2FA code: `，最多 2 次尝试 | `cmd/auth.go:64-110`（`:67` 提示，`:104` `Attempts(2)`） | 已核实 |
| kbsync 缓存是否按 dsid 区分 | **只缓存一条**（`{dsid, guid, data}`），读取时 dsid 与 guid 都匹配才用，否则重新生成；而且 `revoke` 会把它删掉 → **每次切换后，第一次下载都要重新生成 kbsync**（之后同账号复用） | `pkg/appstore/appstore_kbsync_cache.go:13`（key `kbsync-v1`）、`:15-26`（单条）、`:54-68`（覆盖写）、`:70-101`（`:75`、`:89` 比对 dsid/guid）；`appstore_revoke.go:17-22` | 已核实 |

**据此确定的切换流程与 Cookie 拷贝时机**（`Sources/IPADepotCore/AccountSwitcher.swift`）：

1. **保存**当前账号 Cookie：在 revoke 之前（revoke 不碰 Cookie，先后都可以；放在最前面是为了 revoke 失败时 Cookie 也已备份）。
2. `auth revoke`（只在切换前有激活账号时）。
3. **换入**目标账号 Cookie：必须在 `auth login` **之前**，且目标账号没有存档时要**清空**当前 Cookie 文件——因为登录时 Save 会合并磁盘上的旧 Cookie，不清空就会串号。
4. `auth login`；成功后立即再把当前 Cookie 存一份到目标账号（快照，防止崩溃丢失）。之后搜索 / 下载产生的 Cookie 变化在下一次切走时（第 1 步）一并保存。
5. 状态目录按「`~/.ipatool` 存在 → 用它，否则 `XDG_STATE_HOME/ipatool`」解析，与 ipatool 下一次运行时实际使用的目录一致（`~/.ipatool` 存在而新目录不存在时 ipatool 会把旧目录改名迁移过去，写进旧目录的 Cookie 会随之迁移）。
6. 拷贝时没有 ipatool 子进程在运行（队列一次一个任务，切换在两个任务之间；手动切换在有下载时被禁用；切换开始时停掉搜索与历史版本请求），所以没有去抢 `cookies.lock`。

**本机只读观察（仅 `test -d`，未读内容）**：`~/.ipatool` **不存在**，`~/Library/Application Support/IPA Depot/state/ipatool` **存在**。与上面第 3 行一致：0.1.0 第一次运行内置 ipatool 时（设置了 `XDG_STATE_HOME`、新目录尚不存在）ipatool 已把 `~/.ipatool` 改名迁移到 App 的状态目录。影响见「待主会话决定 4」。

## 二、改动清单

### Core（`Sources/IPADepotCore/`）
| 文件 | 内容 |
|---|---|
| `Accounts.swift`（新） | `AccountRegion`（cn/hk/tw/jp/us/kr/other，未知值→other）、`PasswordState`（saved/missing）、`AccountRecord`（id、email、displayName、regionLabel、storefrontHint?、lastLoginAt、passwordState；容错解码；邮箱不区分大小写比较）、`AccountBook`（账号 + activeAccountID）、`AccountStore`（`accounts.json` `{"version":1,…}` 原子写，缺失/损坏视为空，悬空激活 id 视为未激活）、`CurrentAccount`（线程安全的当前账号 id） |
| `CredentialVault.swift`（新） | `CredentialVault` 协议；`KeychainCredentialVault`（`SecItemAdd/CopyMatching/Update/Delete`，service `app.ipadepot.mac.accounts`，account=规范化邮箱，`kSecAttrAccessibleAfterFirstUnlock`，`kSecAttrSynchronizable=false`）；`InMemoryCredentialVault`（测试，可注入故障）；`FileCredentialVault`（**仅 `#if DEBUG`**，冒烟用假账号，Release 中 `strings` 核对为 0） |
| `CookieJarArchive.swift`（新） | 状态目录解析、`save(accountID:)`（无当前 Cookie 时保留旧存档）、`restore(accountID:)`（无存档则清空当前 Cookie）、`clearLive`、`removeArchive`；原子拷贝 = 同目录临时文件（0600）+ `rename` |
| `AccountSwitcher.swift`（新） | `AuthServicing`/`LoginSessioning` 协议移到 Core；`AccountSwitcher` actor：阶段 `idle → savingCookies → revoking → restoringCookies → loggingIn → needsTwoFactor → verifying → done/failed`（另有 `rollingBack`）；`switchTo(_:password:)`、`addAccount(email:password:region:)`、`submitTwoFactorCode`/`cancel`（nonisolated，可同步调用）、`signOut`、`remove`、`setRegion`、`updatePassword`、`migrateIfNeeded`、`reconcile`；`updates()` 进度流（done 带新账号记录，failed 带原因与回滚结果）；回滚：换回原账号 Cookie + 原账号密码重登，失败则未登录并在结果里说明；revoke 失败时先 `auth info` 确认，仍是原账号则不动；密码只在登录成功后写钥匙串；遵循 `DownloadAccountSwitching` |
| `DownloadQueue.swift` | `DownloadAccountSwitching` 协议、`setAccountSwitching(_:)`；新状态 `.switchingAccount`（计入 isActive）；启动任务前 `accountID` 非当前账号则先切换，成功后开始下载，失败置 `.failed(.accountSwitchFailed)` 并继续下一个；切换期间暂停 → 切换后置暂停不下载；取消 → 切换后移除 |
| `DownloadTask.swift` | `DownloadRequest.accountID: UUID?`（不进 ipatool 参数） |
| `DownloadQueueStore.swift` / `DownloadHistory.swift` | `PersistedDownload.accountID?`、`DownloadRecord.accountID?` + `regionLabel?`（下载时的地区快照）；旧文件缺字段照常读取 |
| `VersionCache.swift` / `VersionService.swift` | 缓存键 = App ID + 账号 id：`cache/versions/<账号 id>/<appID>.json`（无账号 id 沿用旧路径）；`VersionService(account:)` 每次调用开始时确定缓存范围 |
| `IpatoolError.swift` | 新类别 `.accountSwitchFailed`（中文文案） |
| `AppPaths.swift` | `accountsFile`、`accountsDirectory` |

### App
| 文件 | 内容 |
|---|---|
| `Logic/AccountsViewModel.swift`（新） | 账号表、切换进度（遮罩 / 验证码 / 提示）、补填密码、迁移选地区、管理操作、地区名（String Catalog）与进度 / 失败文案；`SwitcherLoginSession`（登录窗口复用：实际调用 `switcher.addAccount`，内部与回滚的成功/失败事件不转发） |
| `Views/AccountViews.swift`（新） | 侧栏账号菜单项、切换遮罩（`.ultraThinMaterial` + 卡片，2FA 输入/取消切换）、管理账号 sheet（地区 Picker、密码状态、更新/补填密码、移除并确认）、密码 sheet、迁移选地区 sheet |
| `Logic/AppModel.swift` | 组合账号模型；启动时给队列设切换器、与 `auth info` 对账、0.1.0 迁移；登录/添加账号走切换器；登出 = 保存会话 + revoke（账号保留）；切换成功/失败的状态更新；搜索与历史版本「已切换到 X 账号，请重新搜索」（不自动请求）；切换开始时停掉进行中的搜索/历史版本请求；有下载时禁止手动切换 |
| `Logic/Services.swift` | `AppServices` 增加 `currentAccount`、`switcher`；Debug 且 `IPADEPOT_DATA_ROOT` 被重定向时：密码存 `<数据根>/debug-vault.json`（或 `IPADEPOT_VAULT_FILE`）、Cookie 的主目录指到 `<数据根>/home`——冒烟绝不读写真实钥匙串与 `~/.ipatool` |
| `Logic/LoginViewModel.swift` / `Views/LoginSheet.swift` | `mode`（signIn/addAccount，已有账号时跳过准备页）、地区标签 Picker、回滚说明；准备页第一、四条文案改为多账号行为 |
| `Logic/SearchViewModel.swift`、`VersionsViewModel.swift` + 对应视图 | `.accountChanged` 状态与提示（搜索页可一键「重新搜索」，历史版本页「用当前账号重新获取」，均需手动点） |
| `Logic/DownloadsViewModel.swift`、`Views/DownloadsView.swift`、`Views/HistoryView.swift` | 入队写当前账号 id；`.switchingAccount` 显示「正在切换到 X 账号…」；下载行与记录行显示地区标签（旧记录无账号 → 视为当前账号） |
| `Views/ContentView.swift` | 侧栏底部改为 `Menu`（地区标签 + 显示名 + 邮箱；其他账号、添加账号…、管理账号…、登出当前账号…）；未登录且有已存账号时「选择账号登录」菜单；挂遮罩、各 sheet、切换失败提示 |
| `Views/SettingsView.swift` | 新增「账号」分组（数量 + 管理账号…） |
| `Views/SmokeDriver.swift` | Debug 冒烟模式 `p5Accounts`、`p5Migrate` |
| `Localizable.xcstrings` | 新增 88 个 key（共 239），全部有英文 |

### 版本与文档
`project.yml` `MARKETING_VERSION` 0.2.0；`CHANGELOG.md` 0.2.0 条目；`README.md` 新增「多账号与地区」一节（切换会重新登录、第一次切到某账号可能要验证码、钥匙串可能为 IPA Depot 的账号条目再弹一次授权、密码存本机钥匙串、地区只能换账号改变），功能列表 / 常见问题 / English 段同步。

## 三、测试

```
xcodegen generate                                                        → OK
xcodebuild -scheme IPADepot -configuration Debug … clean build           → BUILD SUCCEEDED，工程告警 0（仅 Xcode 自带 appintentsmetadataprocessor 提示）
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData  → TEST SUCCEEDED
  IPADepotCoreTests  Executed 103 tests, 3 skipped（真机冒烟，默认跳过）, 0 failures   （原 70 + 新 33）
  IPADepotTests      Executed 49 tests, 0 failures                                    （原 39 + 新 10）
  合计 152（原 109 + 新增 43），0 失败
python3 -I scripts/sync-strings.py --check                               → exit 0
```

新增测试（`Tests/IPADepotCoreTests/Phase5CoreTests.swift`、`Tests/IPADepotTests/Phase5ViewModelTests.swift`）：账号表读写 / 损坏 / 容错解码 / 悬空激活 / 邮箱匹配（4）；保险库内存实现、故障注入、钥匙串查询字典（不调用钥匙串）（3）；Cookie 目录解析、原子拷贝与 0600、无存档清空、无当前文件保留存档（4）；切换状态机：成功（顺序、Cookie 内容、密码来源、阶段序列）、2FA、登录失败回滚成功、回滚失败进入未登录、revoke 失败但仍登录不动、revoke 失败已退出则重登、缺密码不动任何东西、补填密码成功后写钥匙串、添加账号（保存/清空/写表）、首次添加不 revoke 并保留 Cookie、移除激活账号、迁移、对账、下载切换错误映射（14）；队列自动切换：先切换后下载、当前账号/旧任务不切换、切换失败任务置失败且队列继续、切换中暂停（4）；版本缓存按账号隔离、VersionService 随当前账号换缓存、旧 queue/history 无账号字段可读、PersistedDownload 账号往返且不进参数（4）；界面：升级迁移弹一次地区、首次启动不迁移、切换后搜索/历史版本清空提示、缺密码先弹框再切换并存钥匙串、失败提示「已恢复为原来的 日本 账号」、入队带账号与地区、登录窗口添加账号、下载中禁止手动切换、切换开始停掉请求、地区名与进度文案（10）。

## 四、Debug 冒烟（假 ipatool，`docs/screenshots/phase5/`）

运行：Debug 包，`IPADEPOT_IPATOOL_PATH=build/smoke-tools/ipatool`（假脚本：`auth info/revoke/login`（PTY 提示、密码校验、Cookie 里没有 `<邮箱>-trusted` 时要 2FA、像 persistent-cookiejar 一样合并写回 Cookie）、`search` 按当前登录账号返回日本区 / 美区不同结果、`download` 记录以哪个账号下载，第一次可设为失败；参数里出现 `-p`/`--password`/密码即判失败），`IPADEPOT_DATA_ROOT=build/smoke-data`，启动参数 `-hasCompletedFirstLogin NO`（参数域）。**真实 ipatool 一次都没有被调用**，真实钥匙串未读写（Debug 冒烟用文件保险库）。

| 步骤 | 结果 | 截图 |
|---|---|---|
| 未登录启动 | 侧栏「登录」 | `p5-01-signed-out.png` |
| 首次登录 = 添加日本账号（地区标签 Picker） | 登录成功，账号表 1 条，密码已存 | `p5-02-add-first-account-sheet.png` |
| 搜索 | 日本区结果（マンガ図書館 / 乗換案内） | `p5-03-search-japan.png` |
| 添加美国账号 | 先保存并 revoke 日本账号，美国账号登录时 Cookie 为空，要求 2FA → 填 123456 → 成功 | `p5-04-add-us-2fa-sheet.png` |
| 切换后搜索页 | 「已切换到 美国 账号，请重新搜索」，侧栏显示「美国 · Smoke us」 | `p5-05-switched-to-us-notice.png` |
| 搜索 | 美区结果（Stream TV / Credit Union） | `p5-06-search-us.png` |
| 管理账号 | 两条，地区 Picker、密码已保存、当前标记、更新密码、移除 | `p5-07-manage-accounts-sheet.png` |
| 手动切回日本 | 遮罩「正在登录 日本 账号」；日本账号 Cookie 已恢复，不需要 2FA | `p5-08-switch-overlay.png`、`p5-09-switched-to-jp.png` |
| 重试美国账号的失败任务（模拟美国 Cookie 过期） | 队列先自动切换：任务显示「正在切换到 美国 账号…」，遮罩要求验证码 → 填入后切换完成 → 下载开始，假 ipatool 记录 `download-as us@example.test` | `p5-10-queue-switch-2fa.png`、`p5-11-downloading-as-us.png`（下载行带「美国」标签） |
| 自动切换后搜索页 | 「已切换到 美国 账号，请重新搜索」 | `p5-12-search-after-auto-switch.png` |
| 升级迁移（`p5Migrate`，假 ipatool 已登录 + `-hasCompletedFirstLogin YES` 参数域） | 自动建账号（地区 other、密码 missing）并弹「请选择该账号的地区」 | `p5-13-migration-region-prompt-sheet.png` |

日志：`smoke-log.txt`、`smoke-log-migrate.txt`、`fake-ipatool-calls.log`。调用日志证实 Cookie 时机正确：`login us … cookies-before=`（空，未串入日本 Cookie）、`login jp … cookies-before=jp@example.test-trusted`（换回日本 Cookie）、每次 `revoke` 时当前 Cookie 为被切走账号的。截图里的账号都是 `@example.test` 假账号（真实账号仍按阶段二规则打码）。冒烟结束后无残留 App / 假 ipatool / sleep 进程。

## 五、Release 产物（`build/release/`，0.2.0 / CFBundleVersion 202610301327）

| 文件 | 大小（字节） | sha256 |
|---|---|---|
| `IPA-Depot-0.2.0-macos-universal.zip` | 41,358,006 | `802a0782cfae5ca792fc86b606cf338da614595e84e3f0172d27f45c87591b5c` |
| `IPA-Depot-0.2.0-macos-universal.dmg` | 46,033,372 | `a3e65fed00132c1c0a1cf8d029e20e77c80454ae20652978e3b75b56a0a0939d` |
| `*.zip.sha256` / `*.dmg.sha256` | 102 / 102 | — |
| `IPA Depot.app` | — | 本地验收用，不上传 |

核对：`shasum -a 256 -c` 两个 OK；`hdiutil verify` VALID；主程序、`Resources/bin/ipatool`、`IPADepotCore.framework` 均 `x86_64 arm64`；`codesign --verify --deep --strict` 通过，`Signature=adhoc`、flags `0x2(adhoc)`（无 Hardened Runtime）、无 sandbox entitlement；`CFBundleShortVersionString=0.2.0`、`LSMinimumSystemVersion=14.0`；主程序 `strings | grep IPADepotSmoke` = 0，Core `strings | grep FileCredentialVault` = 0。旧 `build/release/`（0.1.0）已整体移到 `~/.Trash/ipa-depot-release-0.1.0-20261030/release`。

**Release 启动冒烟**：直接运行主程序，参数 `-hasCompletedFirstLogin NO -ApplePersistenceIgnoreState YES`；20 秒内逐秒 `pgrep -P <pid>` 与 `pgrep -f Resources/bin/ipatool` 均无结果；`CGWindowListCopyWindowInfo` 看到 1040×700 主窗口；`kill -TERM` 结束（退出码 143，同前几期）；无残留进程。真实 `~/Library/Application Support/IPA Depot/` 运行前后 71 个文件 md5 完全一致（未生成 `accounts.json`），`defaults read app.ipadepot.mac hasCompletedFirstLogin` 前后均为 1。

## 六、已知问题

1. **`KeychainCredentialVault` 未对真实钥匙串实测**（红线禁止读写 `app.ipadepot.mac.accounts`）。单元测试只核对查询字典；Debug 冒烟用文件保险库。需用户验收时实测：添加账号后「钥匙串访问」里应出现 `IPA Depot (<邮箱>)` 条目；`kSecAttrAccessibleAfterFirstUnlock` 在 macOS 文件型登录钥匙串上的行为未实测（主流库在 macOS 也这样设置，预期不报错）。
2. **真实切换未实测**（红线）：切换耗时、2FA 是否因保存的 Cookie 而免除，都要用户实测。按源码推断：每次切换 `revoke` 会删除 `kbsync-v1`，**切换后第一次下载要重新生成 kbsync**（组件已缓存时较快，最长 2 分钟超时）；登录后 `ipatool-auth.service` 条目由内置 ipatool 重新创建，之后内置 ipatool 读它预计不再弹授权（未实测）。
3. 添加账号失败且回滚原账号时需要 2FA 的极少见情况：登录窗口会切到验证码页，此时验证码属于**原账号**（进度文字有说明，但页面标题仍是「双重认证」）。
4. 有 sheet（如迁移选地区）打开时 ⌘Q 不会退出 App（macOS 标准行为）；冒烟模式里已先关 sheet。
5. 切换期间进行中的搜索 / 历史版本请求会被取消（子进程随任务取消而 SIGTERM），之后需手动重新搜索——这是有意为之。
6. 沿用：`hdiutil create` 在 macOS 27 打印弃用提示；Release 冒烟以 `kill -TERM` 结束；运行 Debug/Release 时 macOS 会更新真实偏好里的窗口位置。

## 七、待主会话决定（任务书之外 / 有取舍的地方）

1. **「登出」语义**：任务书的菜单只列了账号、添加、管理；我保留了「登出当前账号…」并改为「保存会话 + revoke，账号仍留在列表、可一键切回」（原 0.1.0 登出不保留任何东西）。是否保留这个菜单项与新语义？
2. **启动时 `auth info` 的邮箱不在账号表里**（账号表非空，例如用户在终端用另一个账号登录过）：目前显示该账号信息但不加入列表、无地区标签，切走时不保存它的 Cookie。是否要像迁移一样自动加入（密码待补、弹地区）？
3. **旧下载记录**（无账号 id）的地区标签按任务书「视为当前账号」显示，因此会随切换变化。是否改为迁移时给旧记录统一盖上迁移账号的 id（之后不再变化）？
4. **本机状态目录事实**：0.1.0 已把 `~/.ipatool` 迁移进 `App Support/IPA Depot/state/ipatool`（ipatool 自身行为，见第一节）。后果：用户之后若在终端运行 Homebrew ipatool，会新建一个空的 `~/.ipatool`；之后 App 内置 ipatool 也会改用这个新 `~/.ipatool`（因为 App 的新目录已存在 → ipatool 返回旧目录），Cookie 位置随之改变（CookieJarArchive 的解析与 ipatool 一致，功能不受影响，但已有的受信任 Cookie 会留在旧位置）。是否需要在 README 提示「不要再同时用终端 ipatool」，或让 App 固定使用自己的目录（需要改 `XDG_STATE_HOME` 策略，属于架构调整）？
5. 管理页「更新密码」只写钥匙串、不立即登录验证（下次切换时才验证；切换时输错会走回滚并提示）。是否需要「保存并验证」？
6. Debug 冒烟模式 `p5Accounts` / `p5Migrate` 是否保留在 SmokeDriver（与前几期决定一致，默认保留）。

## 八、收工清理

- `build/` 只剩 `downloads/`（ipatool 官方包缓存）与 `release/`（0.2.0 产物）。
- 已逐项移入 `~/.Trash/ipa-depot-test-cleanup-20261030-phase5/`（未用 rm、未用通配符）：
  - `final/`：`build/DerivedData`、`build/smoke-data`、`build/smoke-downloads`、`build/smoke-shots`、`build/smoke-shots-p5`、`build/smoke-shots-final`、`build/smoke-tools`（假 ipatool 与其状态）、`build/release-build.log`、`$TMPDIR/app.ipadepot.mac.savedState`；
  - `run1/`、`run2/`、`run3/`：前几轮冒烟的数据目录与截图（重跑前移走）；
  - `release-0.2.0-pre/`：修「切换开始停掉请求」之前打的第一版 0.2.0 包（已被现在的包取代）。
- 旧 0.1.0 产物：`~/.Trash/ipa-depot-release-0.1.0-20261030/release`。
- 系统临时目录 `IPADepot*` 为 0 个（测试 tearDown 自删）；无残留 IPA Depot / 假 ipatool / sleep 进程。
- 假 ipatool 脚本源码保留在 `docs/screenshots/phase5/fake-ipatool.sh`（小工装源码，便于复现冒烟）。
- 仓库外的临时文件只在本会话 scratchpad（ipatool v2.7.0 源码下载、英文译文 json、真实数据目录 md5 快照、窗口检测小脚本），未写入其他位置。
