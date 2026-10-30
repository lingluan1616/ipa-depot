# 阶段六（地区浏览 + 发布前小修）进度

更新：2026-10-31 · 状态：**已完成，待主会话验收**（真实账号切换与真实下载按红线未执行）

## 一、改动清单

### Core（`Sources/IPADepotCore/`）
| 文件 | 内容 |
|---|---|
| `RegionCatalog.swift`（新） | `RegionEntry`（地区、中文标签、英文标签、两位国家代码、旗帜、排序）；`RegionCatalog`：cn / hk / tw / jp / us / kr / 其他（国家代码 nil，用户自填）；`region(forCode:)`（目录外的有效代码 → `.other`）、`region(forLabel:)`（中英文）、`countryCode(for:customCode:)`、`resolve(storedValue:)`（兼容旧值：原始值 / 标签文字 / 两位代码）、`normalizeCode`、`flag(forCode:)`。`AccountRecord.countryCode` / `matches(countryCode:)`；`RegionAccountMatch`（current / other / none）与 `AccountBook.match(countryCode:)`（当前账号优先，否则取最近登录的同地区账号） |
| `Accounts.swift` | `AccountRegion` 解码改走 `RegionCatalog.resolve`（旧值按标签文字映射）、`catalogEntry`；`AccountRecord.customRegionCode`（仅「其他」有效，小写；旧文件没有此字段照常读；`regionLabel` 存了 `sg` 之类代码时自动转为「其他 + sg」）。`accounts.json` 格式版本不变，仍写原始值 |
| `PublicCatalogService.swift`（新） | actor；`https://itunes.apple.com/search?term&country&entity&limit`，平台→entity：iphone→software、ipad→iPadSoftware、macos→macSoftware；URLSession（ephemeral，10 秒超时）；结果映射 `AppSummary`（id=trackId、bundleID、name=trackName、version、price、platforms 由 supportedDevices 推断，另带 artworkURL / sellerName / catalogCountry）；无 trackId 的条目跳过、缺字段给默认值；网络 / HTTP 非 200 / 非 JSON 一律映射为 `.networkUnreachable`（原始描述在 raw）；同一组参数（关键词 + 地区 + 平台 + 数量）1 秒内复用上次（或进行中）的结果 |
| `Models.swift` | `AppSummary` 增加可选 `artworkURL` / `sellerName` / `catalogCountry`（默认 nil，ipatool JSON 照常解码）与 `isPublicCatalog` |
| `LegacyAccountStamp.swift`（新） | 迁移盖章：`history.json` / `queue.json` 中 `accountID == nil` 的条目盖上迁移账号 id；只改缺失项，无变化不重写文件（幂等） |
| `AccountSwitcher.swift` | `adoptSignedInAccount(_:) -> AccountAdoption?`：`auth info` 的邮箱不在账号表 → 加入（密码 missing、地区「其他」）并设为当前；`isMigration` = 原表为空。`migrateIfNeeded` 改为调用它（共用代码）。`addAccount(…customRegionCode:)`、`setRegion(_:customCode:for:)` |
| `DownloadQueueStore.swift` | `PersistedDownload.catalogCountry?`（公开目录任务的浏览地区，旧文件无此字段） |
| `AppLookupService.swift` | `prime(_:)`：公开目录结果自带图标地址与开发者，先放进内存缓存，省一次 lookup |

### App
| 文件 | 内容 |
|---|---|
| `Logic/SearchViewModel.swift` | `PublicCatalogSearching` 协议；`BrowseRegion`（followAccount / region(地区, 自填代码)，UserDefaults 键 `browseRegion`，值 `follow` / `us` / `other:sg`）；`setBrowseRegion`（持久化 → 清空结果 → 有关键词时自动重搜）；非跟随时走公开目录（不需要登录）；浏览公开目录时账号切换 / 登出不清空结果、不取消请求 |
| `Logic/AppModel.swift` | `perform(CatalogAction)`：公开目录结果的「历史版本…」「下载最新版」按 `AccountBook.match` 分三支——当前账号匹配直接继续；其他账号匹配 → `accounts.switchTo`（遮罩）并记下 `pendingCatalogAction`，切换成功且新账号地区一致时继续（密码待补时经补密码弹窗同样能继续；有下载进行中时：下载任务直接绑定到该账号由队列自动切换，历史版本则提示稍后再试）；无匹配 → `missingRegionPrompt`；`addAccount(for:)` 打开登录窗口并预选地区（「其他」预填代码），添加成功后自动继续。启动：`adoptSignedInAccount` 替代原迁移调用，迁移时 `LegacyAccountStamp` 盖章并刷新记录页；`bootstrap` 把队列恢复挪到账号对账之后（保证盖章后的队列条目以带账号 id 的形式进内存）。切换后已清空的历史版本模型重新创建 |
| `Logic/AccountsViewModel.swift` | `AccountRegion.flagTitle` / `title(forCode:)` / `title(forStored:)`；`AccountRecord.regionTitle`（「其他（SG）」）/ `regionSnapshot`；`regionTitle(for:snapshot:)`、`regionSnapshot(for:)`；`SwitcherLoginSession` 带自填代码 |
| `Logic/DownloadsViewModel.swift` | `DownloadContext.catalogCountry`；`enqueue(…accountID:)`（可绑定到指定账号）；行的地区名优先取账号，账号未知时公开目录任务用浏览地区；`DownloadRow.isPublicCatalog` |
| `Logic/LoginViewModel.swift` | `customRegionCode`；会话工厂带地区与自填代码 |
| `Logic/HistoryViewModel.swift` | `reload()` |
| `Logic/ArtworkStore.swift`、`Views/ContentView.swift` | 公开目录行先填开发者名与图标地址；「没有 X 地区的账号」提示（「添加账号…」/「取消」）与「暂时无法继续」提示 |
| `Views/SearchView.swift` | 「浏览地区」Picker（跟随当前账号 / 旗帜 + 地区名 / 其他 + 两位代码输入框）；结果行「公开目录」标签；按钮改走 `model.perform`（公开目录行未登录也可点）；空态 / 无结果文案区分公开目录 |
| `Views/AccountViews.swift`、`Views/LoginSheet.swift` | 共用 `RegionPicker`（目录排序 + 旗帜，「其他」时出现国家代码框）与 `RegionCodeField`；管理账号 / 迁移选地区 / 添加账号均用目录；2FA 文案（登录窗口与切换遮罩）改为「验证码已推送到该 Apple ID 的所有受信任设备（含 Apple Watch），请在设备通知中查看。此通道不支持短信验证。」 |
| `Views/DownloadsView.swift`、`Views/HistoryView.swift` | 公开目录任务总是显示地区标签 + 「公开目录」标签；记录页地区名支持自填代码 |
| `Views/SmokeDriver.swift` | Debug 冒烟模式 `p6Browse`（结束时若原本没有 `browseRegion` 偏好则删除，不留在真实偏好里） |
| `Localizable.xcstrings` | 新增 19 个 key（共 257 个在用），全部有英文 |

### 文档
`README.md`：功能列表加「浏览地区」，使用说明加「浏览地区」一条，常见问题补三条（验证码去向与 Apple Watch / 网页登录能转短信但本通道不能；`~/.ipatool` 优先与终端 Homebrew 版 ipatool；浏览地区只影响搜索目录、下载仍需对应地区账号），「搜不到某个 App」一条提到浏览地区，English 段同步。`CHANGELOG.md` 0.2.0 补「浏览地区」与小修。版本仍为 0.2.0。

## 二、测试

```
xcodegen generate                                                       → OK
xcodebuild -scheme IPADepot -configuration Debug … build                → BUILD SUCCEEDED（无源码告警）
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData → TEST SUCCEEDED
  IPADepotCoreTests  Executed 120 tests, 3 skipped（真机冒烟，默认跳过）, 0 failures  （原 103 + 新 17）
  IPADepotTests      Executed 57 tests, 0 failures                                   （原 49 + 新 8）
  合计 177（原 152 + 新增 25），0 失败
python3 -I scripts/sync-strings.py --check                              → exit 0
```

新增测试：`Tests/IPADepotCoreTests/Phase6CoreTests.swift`（17）——目录覆盖 / 排序 / 代码 / 旗帜；标签↔代码双向；代码规范化；旧值兼容解析；`accounts.json` 兼容读取（原始值、中文标签、「其他」+ 自填、两位代码、非「其他」带自填被忽略）与往返；账号匹配三分支（当前 / 其他（取最近登录）/ 无）+「其他」自填代码匹配；Search URL 与 entity；结果映射（价格 0 与非 0、supportedDevices→平台、MacDesktop 不算 Mac、mac-software、artistName 兜底）；缺字段 / 无 trackId / ipatool JSON 无新字段；非 JSON、HTTP 503、断网 → 网络错误；1 秒限速（复用、换地区照常、超 1 秒重发）；迁移盖章幂等且不动已有归属、无变化不重写；启动自动加入（表不为空、非迁移、不重复加入）；空表 = 迁移 + 自填代码保存。`Tests/IPADepotTests/Phase6ViewModelTests.swift`（8）——浏览地区搜索公开目录（未登录可用、不走 ipatool、持久化与恢复）；切换地区清空并重搜 / 「其他」未填不搜 / 跟随账号回到 ipatool；当前账号匹配直接进入历史版本；其他账号匹配自动切换后进入历史版本；无匹配弹提示 → 添加账号预选美国 → 添加成功自动下载（任务绑定新账号、队列显示「美国」、持久化带 catalogCountry）；「其他」地区预填代码；启动自动加入未知账号并弹地区（不盖章）；迁移给旧 history / queue 盖章且记录页与队列内存均已更新。

## 三、Debug 冒烟（`docs/screenshots/phase6/`）

运行：Debug 包，`IPADEPOT_DATA_ROOT=build/smoke-data`、`IPADEPOT_IPATOOL_PATH=build/smoke-tools/ipatool`（假脚本 = 阶段五脚本 + `list-versions` / `get-version-metadata`，源码 `fake-ipatool.sh`）、启动参数 `-IPADepotSmokeMode p6Browse -hasCompletedFirstLogin NO -downloadDirectory build/smoke-downloads`（参数域）。公开目录搜索走真实 `itunes.apple.com`（公开接口）。**真实 ipatool 未被调用**，钥匙串未读写（Debug 冒烟用文件保险库），未碰 `~/.ipatool`。

| 步骤 | 结果 | 截图 |
|---|---|---|
| 添加日本账号后，浏览地区切到「美国」搜 vinyl | 24 条结果全部带「公开目录」标签，图标与开发者来自公开目录（MD Vinyl / Discogs / Mint…） | `p6-01-browse-us-results.png` |
| 点第一条的「历史版本…」 | 弹「没有 美国 地区的账号」+「添加账号…」/「取消」 | `p6-02-no-us-account-alert-sheet.png` |
| 点「添加账号…」 | 登录窗口地区已预选「美国」 | `p6-03-add-us-preselected-sheet.png` |
| 美国账号要 2FA | 新文案（含 Apple Watch、不支持短信） | `p6-04-2fa-copy-sheet.png` |
| 填 123456 | 添加成功后自动进入该 App 的历史版本页（假 ipatool 以 us 账号 list-versions） | `p6-05-continued-to-versions.png` |
| 手动切回日本 | 公开目录结果保留不清空 | `p6-06-back-to-jp-results-kept.png` |
| 再点「历史版本…」 | 自动切换遮罩「切换到 美国 账号 / 正在登录 美国 账号」（Cookie 已恢复，不需 2FA） | `p6-07-auto-switch-overlay.png` |
| 切换完成 | 进入历史版本页 | `p6-08-versions-after-auto-switch.png` |
| 「下载最新版」 | 下载页任务显示「美国」「公开目录」标签（假 download，冒烟最后取消） | `p6-09-queue-public-catalog-tag.png` |

日志：`smoke-log.txt`、`fake-ipatool-calls.log`（Cookie 时机：`login us … cookies-before=`（空）、切回日本 `cookies-before=jp…-trusted`、自动切换 `cookies-before=us…-trusted`；`list-versions-as us@example.test`、`download-as us@example.test`）。冒烟前后真实偏好里均无 `browseRegion` 键（`defaults read app.ipadepot.mac browseRegion` → 不存在），`hasCompletedFirstLogin` 前后均为 1。截图中账号均为 `@example.test` 假账号。

## 四、Release 产物（`build/release/`，0.2.0 / CFBundleVersion 202610301558）

| 文件 | 大小（字节） | sha256 |
|---|---|---|
| `IPA-Depot-0.2.0-macos-universal.zip` | 41,566,736 | `259f3639fe7b9ac03985b25fe63c3ec0c4124da2c2199639722aba48158d50e0` |
| `IPA-Depot-0.2.0-macos-universal.dmg` | 46,421,690 | `6b2f4da82546eee7578f77694a024c807bb2b59bfa1bf9942582a759b650eb9e` |
| `*.zip.sha256` / `*.dmg.sha256` | 102 / 102 | — |
| `IPA Depot.app` | — | 本地验收用，不上传 |

核对：`shasum -a 256 -c` 两个 OK；`hdiutil verify` VALID；主程序、`Resources/bin/ipatool`、`IPADepotCore.framework` 均 `x86_64 arm64`；`codesign --verify --deep --strict` 通过，`Signature=adhoc`、flags `0x2(adhoc)`；`CFBundleShortVersionString=0.2.0`、`LSMinimumSystemVersion=14.0`；主程序 `strings | grep IPADepotSmoke` = 0，Core `strings | grep FileCredentialVault` = 0。旧 `build/release/`（上一版 0.2.0）已整体移到 `~/.Trash/ipa-depot-release-0.2.0-pre-20261030/release`。

**Release 启动冒烟**：为避免读写用户真实数据（真实 `accounts.json` 已存在，`-hasCompletedFirstLogin NO` 启动时对账会把激活账号写空），以 `CFFIXED_USER_HOME=build/release-smoke-home` 运行主程序，参数 `-hasCompletedFirstLogin NO -ApplePersistenceIgnoreState YES`；20 秒内逐秒 `pgrep -P <pid>` 与 `pgrep -f Resources/bin/ipatool` 合计 0；20 秒时进程存活；`osascript … quit` 正常退出（**退出码 0**，前几期为 `kill -TERM` 的 143）；无残留进程。真实 `~/Library/Application Support/IPA Depot/` 73 个文件运行前后 mtime + 大小完全一致（只 stat，未读内容）。窗口截图未做（未申请屏幕控制）。

## 五、已知问题

1. **公开目录网速**：本机实测 `itunes.apple.com/search` 单次 6–12 秒，偶有超时（任务书定的 10 秒超时）；超时显示「搜索失败」+ 重试按钮。冒烟中一次成功。
2. 搜 Mac（entity=macSoftware）时 Apple 也会返回可在 Apple 芯片 Mac 上运行的 iOS App（`kind=software`，supportedDevices 含 `MacDesktop`）。按任务书「platforms 由 supportedDevices 推断」，这类结果平台标为 iPhone / iPad，不标 Mac；但行的下载平台仍沿用搜索时选的 Mac（与 ipatool 搜索的既有行为一致），下载可能因平台不符失败（已有 `packagePlatformMismatch` 文案）。
3. 公开目录结果的价格以浏览地区货币计（例如美区 4.99 美元），沿用原价格格式化（不带币种）。
4. 「其他」地区的国家代码在搜索页输入满两位即生效；Picker 选「其他」但未填代码时显示「请填写国家代码」，不发请求。
5. 已安装在 /Applications 的上一版 0.2.0 用户：迁移已在上一版完成且**没有盖章**（盖章只在本版的迁移路径执行），其旧记录仍按「无账号 = 当前账号」显示。见待决 2。
6. 真实账号切换、真实 2FA 推送到 Apple Watch 的行为未实测（红线），需用户验收。
7. 沿用：`hdiutil create` 弃用提示；运行 Debug 时 macOS 会更新真实偏好里的窗口位置。

## 六、待主会话决定

1. **提交信息署名**：任务书要求 `Co-Authored-By: Claude Fable 5.1`，本次提交按会话的署名要求写为 `Claude Opus 5.5`（实际执行模型）。如需统一请主会话改写（本地未 push，可 `commit --amend`）。
2. **已装上一版 0.2.0 的旧记录补盖章**：用户本机 `accounts.json` 已由上一版迁移生成，本版不会再走迁移路径。是否增加一次性补盖（例如账号表只有一个账号、且存在无账号记录时，盖上该账号 id，并以偏好标志防重复）？涉及推断「迁移账号」，未自行实现。
3. 公开目录 + 有下载进行中时点「下载最新版」：当前实现直接把任务绑定到匹配地区的账号，排队轮到时由队列自动切换（不弹遮罩确认）。是否接受，或改为与「历史版本」一样提示稍后再试？
4. 公开目录模式下，账号切换 / 登出不清空搜索结果（结果与账号无关）。与跟随模式的「切换后清空」不同，是否接受？
5. Debug 冒烟模式 `p6Browse` 是否保留（默认保留，与前几期一致）。
6. Release 启动冒烟改用 `CFFIXED_USER_HOME` 隔离（因真实 `accounts.json` 已存在）。建议后续 RELEASING.md 也写明这一点，是否更新？

## 七、收工清理

- `build/` 只剩 `downloads/` 与 `release/`。
- 逐项移入 `~/.Trash/ipa-depot-test-cleanup-20261030-phase6/`（未用 rm、未用通配符）：`build/DerivedData`、`build/smoke-data`、`build/smoke-downloads`、`build/smoke-shots-p6`、`build/smoke-tools`、`build/release-smoke-home`、`build/release-build.log`、`$TMPDIR/app.ipadepot.mac.savedState`、scratchpad 的英文译文 json 与真实数据 stat 快照、一次接口探测的响应文件 `probe-search.json`。
- 系统临时目录 `IPADepot*` 为 0 个；无残留 IPA Depot / 假 ipatool 进程；scratchpad 不留文件。
- 假 ipatool 脚本源码保留在 `docs/screenshots/phase6/fake-ipatool.sh`。
