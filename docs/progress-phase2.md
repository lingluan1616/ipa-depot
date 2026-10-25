# 阶段二（SwiftUI 界面层）进度

更新：2026-10-26 · 状态：**已完成，待主会话验收**

## 已完成

| 项 | 结果 | 位置 |
|---|---|---|
| Locator 兜底顺序 | `IPADEPOT_IPATOOL_PATH`（设置且可执行）→ 内置 → `/opt/homebrew/bin/ipatool` → `/usr/local/bin/ipatool`。**环境变量与两条兜底只在 Debug 构建生效**，Release 只认内置二进制 | `Sources/IPADepotCore/IpatoolLocator.swift` |
| 下载队列 | `DownloadQueue` actor：同一时刻只跑一个 `DownloadTask`，其余排队；`add / pause / resume / cancel / remove / removeCompleted / updates()`（快照流，订阅即发当前快照）；事件与结果走同一个有序流回到 actor | `Sources/IPADepotCore/DownloadQueue.swift` |
| Core 其他新增 | `AppLookupService`（iTunes Lookup，cn→us→jp，缓存 `cache/artwork/`）、`HistoryStore`/`DownloadRecord`、`DownloadFileNamer`、`UpdateChecker`/`VersionComparator`、`DirectoryUsage`、`HTTPFetching`、`AppPaths.artworkCacheDirectory/historyFile`、错误映射补 `unexpected eof`/`send sap request` → 网络错误（冒烟实测到的原始错误） | `Sources/IPADepotCore/` |
| 界面 | `NavigationSplitView`：侧栏 搜索/下载/记录/设置 + 底部账号区（已登录：姓名、邮箱、登出；未登录：登录）；窗口默认 1040×700、最小 860×560；`⌘,` 跳到设置页 | `App/Views/ContentView.swift` |
| 登录 sheet | 准备页（三条说明 + SF Symbols 画的钥匙串授权框示意）→ Apple ID/密码（回车提交）→ 6 位验证码（本地校验）；进度文字来自 `LoginEvent`；失败显示 `IpatoolError.message` + 「查看原始错误」折叠区；登出有确认框 | `App/Views/LoginSheet.swift`、`App/Logic/LoginViewModel.swift` |
| 搜索页 | 搜索框 + 平台（iPhone/iPad/Mac）+ 数量（10/25/50）；行：图标、名称、平台标签、开发者（有才显示）、Bundle ID、版本、价格、「下载最新版」「历史版本…」；空结果 / 未登录 / 失败各有空态 | `App/Views/SearchView.swift` |
| 历史版本 | 搜索页导航栈内推入；ID 倒序（最新在上）；**只加载可见区域上 2 行到下 5 行**，每批 10 个，滚动继续；失败行可重试；`.licenseRequired` 时免费 App 提供「领取免费许可并下载最新版…」，付费 App 提示先购买 | `App/Views/VersionsView.swift`、`App/Logic/VersionsViewModel.swift` |
| 下载页 | 进行中 / 已完成分组；图标、名称、版本、进度条（无比例时不确定样式）、百分比、已下载/总大小、速度、状态；暂停/继续/重试/取消/在访达中显示/移除；完成即写记录；`licenseRequired` 弹「该 App 尚未加入你的账号，是否领取免费许可后下载？」，确认后 `purchase: true` 重下 | `App/Views/DownloadsView.swift`、`App/Logic/DownloadsViewModel.swift` |
| 文件名 | `<name>_<version>.ipa`，替换 `/\:*?"<>|`、控制符、开头的点；同名（含 `.tmp` 残留、队列已占用）加 ` (2)` 序号；版本号未加载时用外部版本 ID | `DownloadFileNamer` |
| 记录页 | `~/Library/Application Support/IPA Depot/history.json`；在访达中显示、移除单条、清空（确认框，不删文件）；文件不在时半透明 + 「文件已不存在」 | `App/Views/HistoryView.swift` |
| 设置页 | 下载目录（`NSOpenPanel`，默认 `~/Downloads/IPA Depot`，**真正下载时才创建**）；缓存：版本缓存与图标缓存大小 + 清理（只清 `cache/versions` 与 `cache/artwork`）；关于：App 版本、ipatool 版本、项目地址占位、「基于 majd/ipatool（MIT）」+ 许可全文 sheet；检查更新（`ProjectInfo.owner` 为 nil 时禁用） | `App/Views/SettingsView.swift`、`App/Logic/SettingsViewModel.swift` |
| 字体（主会话追加） | 阿里妈妈数黑体拷到 `App/Resources/Fonts/`，以文件夹拷进 `Contents/Resources/Fonts/`，`App/Info.plist` 的 `ATSApplicationFontsPath = Fonts`（与生成的 Info.plist 合并）；冒烟实测 `NSFont(name: "AlimamaShuHeiTi-Bold")` 可用。**使用范围**见下方「字体使用范围」 | `App/Views/Typography.swift` |
| 字体许可 | 从官方字体站「阿里妈妈数黑体 → 法律声明」链接取到原文（语雀文档），原样写入许可文件并注明来源；README 致谢加一行 | `App/Resources/Fonts/阿里妈妈数黑体-许可.txt` |
| 本地化 | `App/Localizable.xcstrings`（源语言 zh-Hans，144 条 key 全部有 en 译文）；`scripts/sync-strings.py` 从编译器抽取的 stringsdata 同步 key、`--check` 检查缺失 | `App/Localizable.xcstrings`、`scripts/sync-strings.py` |
| App 图标 | `scripts/make-app-icon.swift`：CoreGraphics 画深灰圆角方底 + 白色等轴测包装盒、封箱胶带、侧面向下箭头；16–1024 共 10 张 | `App/Assets.xcassets/AppIcon.appiconset` |
| 架构 | MVVM：`@Observable @MainActor` 视图模型；服务协议（`AuthServicing` / `LoginSessioning` / `SearchServicing` / `VersionServicing` / `AppLookupProviding` / `DownloadQueueing` / `UpdateChecking` / `KeyValueStoring`）注入，组合根 `AppServices.live()` | `App/Logic/` |
| 测试 | 新增 `IPADepotTests`（26 个，视图模型）+ `IPADepotCoreTests/Phase2CoreTests.swift`（22 个，Core 新增部分）；**总计 86 个，83 通过、3 个真机冒烟用例默认跳过，0 失败** | `Tests/` |
| 界面冒烟 | Debug 构建、Homebrew ipatool，真实出数据，截图见下 | `docs/screenshots/` |

### 验收命令结果

```
xcodegen generate
xcodebuild -scheme IPADepot -configuration Debug -derivedDataPath build/DerivedData build   → BUILD SUCCEEDED，exit 0
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData                     → TEST SUCCEEDED，exit 0
  IPADepotCoreTests.xctest  Executed 60 tests, with 3 tests skipped and 0 failures
  IPADepotTests.xctest      Executed 26 tests, with 0 failures
grep -rn "IPADEPOT_IPATOOL_PATH" App/      → 无输出
```

告警：编译器与工程告警为 0。日志里唯一的 `warning:` 行是 Xcode 自带工具 `appintentsmetadataprocessor … Metadata extraction skipped, no AppIntents.framework dependency found`（阶段一已知问题 9，与本工程代码无关，无对应构建设置可关）。

`grep -rni password App/`（排除 xcstrings）共 8 处，全部在允许范围：`LoginViewModel` 的 `password` 属性（SecureField 绑定）、提交时取值后立即清空、`session.login(email:password:)` 调用、`LoginSessioning` 协议声明（与 `LoginSession` 同形）、`LoginSheet` 的 `SecureField(... $login.password)` 与 `.textContentType(.password)`。无日志、无持久化、无命令行参数路径。

### 测试覆盖（新增 48 个）

- 视图模型（26）：登录状态机 6（无 2FA 成功并清空密码、2FA 本地校验与回填、验证码错误重新输入、失败文案与原始错误、取消不报错、输入规则与日志文案）；搜索 4（结果映射/去重/价格/平台标签、空结果与未登录、网络错误含大陆提示、平台取值）；历史版本 5（倒序与最新标记、可见区域分批懒加载与滚动、失败重试、licenseRequired 与下载上下文、其他错误）；下载 5（文件名清洗与同名序号、完成写记录并移到已完成、licenseRequired 提示并 purchase 重下、付费 App 不领取、行文案映射）；记录/设置/根模型 6（记录持久化与排序与灰显、下载目录设置、清理只动 cache、检查更新禁用/可用、启动账号状态三种、登录成功关闭 sheet 与登出清空界面）。
- Core（22）：Locator 4、DownloadQueue 8（单任务串行、暂停继续、排队项暂停跳过、取消运行项并删 `.tmp`、取消排队项、失败重试、事件顺序、快照流）、文件名/记录/目录占用/路径 5、Lookup 与更新检查 5。

## 冒烟截图清单（2026-10-26 05:02，`docs/screenshots/`）

运行方式（Debug 构建，环境变量只在 Core 的 Locator / AppPaths 里读取）：

```sh
IPADEPOT_IPATOOL_PATH=/opt/homebrew/bin/ipatool IPADEPOT_DATA_ROOT=$PWD/build/smoke-data \
  "build/DerivedData/Build/Products/Debug/IPA Depot.app/Contents/MacOS/IPA Depot" \
  -IPADepotSmokeOutput $PWD/build/smoke-shots -ApplePersistenceIgnoreState YES
```

`-IPADepotSmokeOutput` 触发 Debug 专用的 `SmokeDriver`（`App/Views/SmokeDriver.swift`，`#if DEBUG`）：自动走完流程并只截本 App 自己的窗口，然后退出。截图时账号区显示为「Apple ID / •••@•••」，日志不记录姓名邮箱；设置页路径显示为 `~/…`。**没有执行登录、登出、领取许可、下载**（登录 sheet 只打开到第二步、未输入任何内容）。

| 文件 | 内容 |
|---|---|
| `00-signed-out.png` | 未登录状态（仅切换显示状态，未登出）：侧栏底部「登录」、搜索页「尚未登录」空态 |
| `01-launch.png` | 已登录启动，搜索页初始空态，四个侧栏页面 |
| `02-login-intro-sheet.png` | 登录准备页：三条说明 + 钥匙串授权框示意（「始终允许」高亮） |
| `03-login-credentials-sheet.png` | Apple ID / 密码页（空） |
| `04-search-results.png` | 搜索「音乐」→ 22 条真实结果，图标（iTunes Lookup）、开发者、版本、价格、平台标签 |
| `05-versions.png` | 1606306441 谜底黑胶：141 个版本，最新在上；首屏 13 个版本号与日期已加载（3.8.5 2026-10-24、3.8.4、3.8.3…） |
| `06-downloads.png` / `07-history.png` / `08-settings.png` | 下载空态 / 记录空态 / 设置页（内置 ipatool 2.7.0、缓存大小、许可、更新按钮禁用） |
| `smoke-log.txt` | 冒烟日志（字体已加载、搜索行数、版本加载数与批次数） |

冒烟中观察到：第一次跑时 `list-versions` 报 `fetch SAP certificate … s.mzstatic.com … unexpected EOF`（网络中断，重跑即成功）。原先映射为「未知错误」，已在 Core 映射规则里补成网络错误并加测试。

## 字体使用范围

- 用数黑体：登录 sheet 三个步骤的大标题；历史版本页头部 App 名；搜索结果、下载、记录列表里的 App 名；搜索结果的版本号、历史版本列表的版本号；下载页的版本号、百分比、大小、速度；记录页的版本号与文件大小。
- 仍用系统字体：正文、说明、按钮、表单、空态、侧栏、设置页、日期、Bundle ID、外部版本 ID。
- 字号按 macOS 文本样式对应（title2 22 / headline 14 / body 13 / callout 12 / caption 11），并用 `relativeTo:` 跟随动态字号；字体缺失或缺字时系统自动回退。

## 未完成

- 无（任务书 1–10 项与字体追加要求均已完成）。真实登录 / 登出 / 领取许可 / 下载按红线未执行，下载页的进度样式只在单元测试里用假任务验证过。

## 已知问题与注意事项

1. **窗口工具栏里的页面标题仍是系统字体**（「搜索」「下载」等）。SwiftUI 的 `navigationTitle` 不能换字体，要换只能隐藏系统标题、自己在工具栏或内容区画标题，见「待主会话决定」。
2. 冒烟截图用的是 Debug 专用的自窗口截图（按符号动态调用 `CGWindowListCreateImage`，只取本进程窗口，不截全屏、没有弹权限框）。Release 构建不含这段代码。
3. 历史版本元数据每个 ID 一次 ipatool 调用（并发 3），实测首屏 13 个约 80 秒（第二次走缓存，十几秒）。只加载可见附近的行，141 个全部看完需要一直往下滚。
4. 下载队列不跨启动保存：退出 App 时排队 / 暂停的任务会丢失，已下了一半的 `<文件>.ipa.tmp` 留在下载目录里（下次同名下载会避开它另起序号，不会续上）。
5. 「取消」会删除该任务的 `<目标>.ipa.tmp`（本 App 发起的未完成文件）；「暂停」保留以便续传。
6. Core 的错误文案（`IpatoolError.message`）只有中文；英文界面下错误说明仍是中文。
7. `IPADepotTests` 不启动宿主 App：把 `App/Logic/`（视图模型与服务协议，不含 SwiftUI 视图）直接编进测试包。这样跑测试不会触发 App 启动时的 `auth info`，不会弹钥匙串框。
8. 下载 URL 会话改为 ephemeral（图标与查询结果由本 App 缓存在 `cache/artwork/`）。改之前的冒烟已在 `~/Library/Caches/app.ipadepot.mac/`（3.5 MB，系统 URL 缓存）留下文件，按红线未删，见下方清单。
9. 冒烟让 `~/Library/Preferences/app.ipadepot.mac.plist` 多了窗口位置（阶段一启动时就已创建该文件）；`~/Library/Application Support/IPA Depot/` 仍只有阶段一留下的空 `state/`（本阶段冒烟数据都在 `build/smoke-data`，已清）。

## 待主会话决定

1. **启动时的钥匙串弹窗时机**：App 一启动就调 `auth info`。正式版用内置二进制，而用户现有的钥匙串条目是 Homebrew 版创建的，所以**用户在看到准备页之前就会先弹系统授权框**（新用户没有条目则不弹）。可选：首次启动先显示一页说明再查账号；或先不查、等用户点「登录」/搜索时再查。
2. **工具栏页面标题是否要换数黑体**（见已知问题 1）：要换需隐藏系统标题、改成自绘标题，会偏离系统设置那种原生观感。目前保持系统字体。
3. **字体许可**：法律声明第 4 条禁止「单独定价出售、出租、出借、转让、转授权」，第 3 条允许免费用于商业或非商业用途。随免费开源 App 一起分发未被明文禁止，但开源仓库直接放 ttf 文件是否算「转授权」原文没写，请主会话判断是否需要向 `puhuiti_feedback@alibaba-inc.com`（字体站页脚的授权联系方式）确认。README 已注明字体不在 MIT 范围内。字体文件 1.3 MB 已提交进 git。
4. **Release 构建的 Locator 语义**：Release 不读 `IPADEPOT_IPATOOL_PATH`，也不兜底 Homebrew 路径（`developmentFallbacks` 为空），这样「正式运行只用内置」是硬保证。若阶段三想用 Release 包做冒烟，需要改成按 Debug 包冒烟或另议。另外新增了 Debug 专用的 `IPADEPOT_DATA_ROOT`（把数据目录指到 `build/`，冒烟不写真实数据目录）。
5. 仓库外残留（按红线未删）：`~/Library/Caches/app.ipadepot.mac/`（3.5 MB，冒烟时系统 URL 缓存，改 ephemeral 后不会再产生）、`~/Library/Preferences/app.ipadepot.mac.plist`（窗口位置）。是否清理由主会话决定。
6. 下载队列是否要跨启动持久化（已知问题 4）。

## 给阶段三的说明

- 发布前把 `App/Logic/SettingsViewModel.swift` 里的 `ProjectInfo.owner` 填上 GitHub 账号名，项目地址与检查更新会自动启用。
- 新增或修改界面文案后：构建一次 → `python3 -I scripts/sync-strings.py --check`，缺英文会列出来。
- 字体文件随 App 打包在 `Contents/Resources/Fonts/`，许可文件在同目录。
