# 阶段一（引擎层）进度

更新：2026-10-26 · 状态：**已完成，待主会话验收**

## 已完成

| 项 | 结果 | 落盘位置 |
|---|---|---|
| 仓库骨架 | `project.yml`（xcodegen）、`.gitignore`、`LICENSE`（MIT，2026 IPA Depot contributors）、`README.md` 占位 | 仓库根 |
| App target `IPADepot` | macOS 14.0、SwiftUI 占位窗口、Bundle ID `app.ipadepot.mac`、产品名 `IPA Depot.app`；**无 App Sandbox、无 Hardened Runtime**、ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`）；Swift 5 语言模式 | `App/` |
| 框架 `IPADepotCore` + 测试 `IPADepotCoreTests` | 纯 Swift，只依赖 Foundation / Darwin / Compression，不依赖 SwiftUI | `Sources/IPADepotCore/`、`Tests/IPADepotCoreTests/` |
| ipatool 拉取脚本 | `scripts/fetch-ipatool.sh`：下载 v2.7.0 官方 arm64 + amd64 包与 `.sha256sum` → 校验 → 解压到 `build/extract-*`（用完自删，不在其中执行任何脚本）→ `lipo -create` → `vendor/ipatool/ipatool`（755）+ `LICENSE` + `VERSION` | `scripts/`、`vendor/ipatool/` |
| 构建阶段内置 | `scripts/embed-ipatool.sh`（xcodegen postCompileScripts）：先核对 sha256 与 `VERSION` 一致，再拷到 `Contents/Resources/bin/ipatool`（755）并 `codesign --force -s -`，同时拷 `Contents/Resources/ipatool-LICENSE` | `scripts/embed-ipatool.sh` |
| 引擎 | 进程封装、zerolog JSON 行解析、PTY 登录、auth info/revoke、搜索、版本列表 + 元数据（并发 ≤3、磁盘缓存）、下载（进度条解析 + `.tmp` 轮询兜底、暂停/继续、IPA 校验）、错误映射 | 见下方接口表 |
| 单元测试 | **35 个单元测试全绿**（另有 3 个真机冒烟用例，默认跳过，共 38） | `Tests/IPADepotCoreTests/` |
| 真机只读冒烟 | `--version`、`search "音乐" --limit 3`、`list-versions -i 1606306441` 全部通过 | 见下方摘录 |

### ipatool 二进制核对

```
lipo -info vendor/ipatool/ipatool → Architectures in the fat file: x86_64 arm64
vendor/ipatool/ipatool --version  → ipatool version 2.7.0
codesign -dv                      → flags=0x20002(adhoc,linker-signed)（官方包原样；构建进 App 时重新 ad-hoc 签名）
大小 83,253,122 字节
```

`vendor/ipatool/VERSION`（官方 `.sha256sum` 原文：arm64 `5ae100d4…aca33`、amd64 `05f48994…92263`，与下列一致）：

```
ipatool 2.7.0
source: https://github.com/majd/ipatool/releases/download/v2.7.0/
sha256 ipatool-2.7.0-macos-arm64.tar.gz 5ae100d4520cf4b3f4374239e5925a9ad9a8dc02abc16bae27479e7ae99aca33
sha256 ipatool-2.7.0-macos-amd64.tar.gz 05f48994d8b3cfefe7ea1172a0ac0b28715888e9df0af38cf3e490d2ed592263
sha256 ipatool(universal, lipo merged) 6c55a0d471e62760b6402e4071d6318d6e9aed198e8db8f025f8001b52627cf9
```

### 构建与测试命令（均退出码 0）

```sh
xcodegen generate
xcodebuild -scheme IPADepot -configuration Debug -derivedDataPath build/DerivedData build   # BUILD SUCCEEDED，0 warning
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData                     # Executed 38 tests, 3 skipped, 0 failures
```

App 包实测：`Contents/Resources/bin/ipatool` 为 universal、`Signature=adhoc`；`codesign --verify --deep --strict` 通过；App 无 entitlements（即无沙盒），flags=0x2(adhoc)（无 runtime）。直接运行 App 可执行文件，`System Events` 能看到名为 “IPA Depot” 的窗口。

## 真机冒烟输出摘录（2026-10-26 04:2x，通过 `SmokeTests` 调用引擎）

运行方式：

```sh
TEST_RUNNER_IPADEPOT_SMOKE_IPATOOL=/opt/homebrew/bin/ipatool \
TEST_RUNNER_IPADEPOT_SMOKE_VENDOR=$PWD/vendor/ipatool/ipatool \
TEST_RUNNER_IPADEPOT_SMOKE_OUT=$PWD/build/smoke.txt \
xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData -only-testing:IPADepotCoreTests/SmokeTests
```

```
[--version] smoke ipatool /opt/homebrew/Cellar/ipatool/2.7.0/bin/ipatool -> 2.7.0
[--version] vendor ipatool /Users/lingluan/Documents/claude/ipa-depot/vendor/ipatool/ipatool -> 2.7.0
[search "音乐" --limit 3] 3 个结果
  - id=414603431 bundleID=com.tencent.QQMusic name=QQ音乐 - 听我想听 version=20.9.6 price=0.0 platforms=["iphone", "ipad", "watchos"]
  - id=472208016 bundleID=com.kugou.kugou1002 name=酷狗音乐 - 就是歌多 version=20.8.6 price=0.0 platforms=["iphone", "ipad", "watchos"]
  - id=1605585211 bundleID=com.soda.music name=汽水音乐 - 随时听好歌 version=21.3.1 price=0.0 platforms=["iphone", "ipad", "macos"]
[list-versions -i 1606306441] 141 个版本 ID，bundleID=-
  前 3 个: 846770304, 847384601, 847486518
  后 3 个: 893275962, 893564475, 893783327
  缓存文件已写入: true
```

说明：search / list-versions 用的是 Homebrew 的 ipatool（创建钥匙串条目的那份二进制），没有用内置二进制——内置二进制读钥匙串会弹系统授权框（调研 3.2），冒烟不应在用户屏幕上弹窗。`--version` 两份都跑了。冒烟的 `XDG_STATE_HOME` / 缓存目录用的是系统临时目录下的子目录，跑完即删。list-versions 单次约 30 秒（网络往返），属正常。

## 未完成

- 无（任务书 1–7 项均已完成）。真实登录 / 下载 / revoke 按红线未执行，由主会话验收。

## 已知问题与注意事项

1. **list-versions 用 `-i` 时 ipatool 返回的 `bundleID` 是空字符串**（真机实测原始 JSON：`"bundleID": ""`）。引擎已把空串视为 nil；阶段二需要 bundleID 时用搜索结果里的值。
2. **PTY 接法与任务书略有不同**：ipatool 的交互提示写在 **stderr**（v2.7.0 `cmd/prompt.go`：“Prompts belong on stderr”），所以实现为 **stdin + stderr 接伪终端从端，stdout 走管道**，JSON 结果保持干净。从端关闭 ECHO，邮箱/验证码不会回显；密码由 ipatool 自己 `MakeRaw` 读取（回显为 `*`）。已用假 ipatool 脚本端到端验证（`[ -t 0 ]` 判 TTY、argv 中不出现密码、2FA 回填）。
3. **登录时邮箱也走提示写入**（不传 `-e`）。`ipatool auth login --help` 把 `-e` 标为 required，但这只是说明文字；源码在交互模式下 email 为空时会提示 `enter Apple ID (email address or phone number): `。真实登录尚未验证（红线），主会话验收时请留意这一点。
4. 本地校验 2FA：`submitTwoFactorCode` 先在本地要求 6 位数字，不合格直接抛 `.invalidAuthCodeFormat`，不会消耗 ipatool 的重试机会（ipatool 交互模式只给 2 次）。
5. 子进程退出后最多再等 1.5 秒收尾输出（防止孙进程继承管道导致 EOF 不来）；ipatool 本身没有子进程，正常情况下不受影响。
6. `grep '"-p"\|--password'` 唯一命中在 `Tests/IPADepotCoreTests/ZipAndProcessTests.swift`：那是假 ipatool 脚本里的**防泄漏断言**（参数里出现 `-p` / `--password` / 密码明文就让测试失败），不是传参路径。`Sources/`、`App/`、`scripts/` 无命中。
7. 进度条格式按 schollz/progressbar（ipatool 用 `OptionShowBytes + OptionShowCount`）写了容错正则，支持 `12/45 MB`、`512 kB/1.5 GB`、`KiB/MiB`、无速度、ANSI 转义、`\r` 刷新；真实下载时的样式尚未实测（红线）。解析不到时 1 秒轮询 `<输出>.tmp` 大小兜底。
8. 运行 App 会创建 `~/Library/Application Support/IPA Depot/state/`（空目录，`XDG_STATE_HOME`）。本次启动验证已创建该目录，按红线未删除，请主会话决定是否清理。
9. Xcode 27.1 构建时有一条与本工程无关的系统提示 `appintentsmetadataprocessor … Metadata extraction skipped`，可忽略。

## 待主会话决定

1. **`vendor/ipatool/ipatool`（83 MB）没有提交进 git**，在 `.gitignore` 里。理由：GitHub 单文件超过 50 MB 会警告（100 MB 拒收），而且每次升级 ipatool 都会让仓库历史多出 80 MB。现在的做法是提交 `LICENSE` 和 `VERSION`（sha256 锁定）；克隆后运行 `scripts/fetch-ipatool.sh` 重建二进制，构建阶段会核对 sha256，缺文件就报错。如果要入库，执行 `git add -f vendor/ipatool/ipatool` 即可；也可以改为在 Release 构建时由 CI 拉取。
2. 是否把开发期兜底路径扩展为 `/usr/local/bin/ipatool`（Intel Homebrew）。当前按任务书只兜底 `/opt/homebrew/bin/ipatool`。
3. 阶段二是否需要「首次读取钥匙串会弹系统授权框」的预提示页（调研 3.2）。内置二进制和 Homebrew 版不是同一份，用户第一次用 App 时一定会弹。

## 给阶段二的接口说明（`import IPADepotCore`）

| 类型 | 说明 |
|---|---|
| `AppPaths` | 数据目录布局；`.default` = `~/Library/Application Support/IPA Depot`，含 `stateDirectory` / `versionsCacheDirectory` |
| `IpatoolLocator` | `locate() throws -> URL`（App 内置 → `/opt/homebrew/bin/ipatool`）；`detectVersion() async throws -> String` |
| `IpatoolRunner` | 持有可执行文件 + `AppPaths`；`run(args, interactive:, onLine:) async throws -> IpatoolProcess.Result`（自动加 `--format json`/`--non-interactive`，失败抛 `IpatoolError`）；`makeProcess(...)` |
| `IpatoolEnvironment` | `make(base:paths:)`：当前环境 + `XDG_STATE_HOME`，不覆盖 `HOME` |
| `IpatoolProcess` | 单次子进程；`run(onLine:onTerminalOutput:) async throws -> Result`；`cancel(gracePeriod:)`（SIGTERM → 超时 SIGKILL）；Swift 任务取消时自动终止 |
| `IpatoolProcess.Result` | `exitCode` / `events` / `textLines` / `wasCancelled`；`errorEvent`、`lastEvent(containing:)` |
| `IpatoolLine` / `IpatoolLineParser` | 一行输出 = `.json(IpatoolLogEvent)` 或 `.text(String)` |
| `IpatoolLogEvent` | zerolog 行：`level/time/message/error/success/fields/rawData`，`decode(_:)` |
| `JSONValue` | Sendable 的任意 JSON 值 |
| `LineBuffer` | 字节流按 `\n`/`\r` 切行、去 ANSI |
| `PseudoTerminal` | `posix_openpt` 伪终端；`write(_:)` |
| `LoginSession` | `login(email:password:onEvent:) async -> Result<AccountInfo, IpatoolError>`；`submitTwoFactorCode(_:) throws`；`cancel()`；`state` |
| `LoginEvent` / `LoginState` | `.preparing` `.needsTwoFactor` `.verifyingTwoFactor` `.log` `.succeeded` `.failed` / 对应状态 |
| `LoginPrompt` / `LoginPromptDetector` | 识别 `enter Apple ID` / `enter password:` / `enter 2FA code:` |
| `AuthService` | `info() async throws -> AccountInfo`（未登录抛 `.notLoggedIn`）；`revoke()`（已封装，阶段一未调用） |
| `AccountInfo` | `name` / `email` |
| `SearchService` | `search(_:limit:platform:) async throws -> [AppSummary]`（默认 iphone） |
| `AppSummary` | `id` / `bundleID` / `name` / `version` / `price` / `platforms` / `isFree` |
| `VersionService` | `listVersionIDs(appID:) async throws -> [String]`；`metadata(appID:versionID:)`；`metadata(appID:versionIDs:onEach:)` 批量（并发 ≤3，逐个回调，读写缓存）；无授权抛 `.licenseRequired` |
| `VersionMetadata` | `externalVersionID` / `displayVersion` / `releaseDate: Date?` |
| `VersionCache` / `CachedVersions` | `cache/versions/<appID>.json` 读写（原子写，损坏即忽略） |
| `DownloadTask` | `start(onEvent:) async -> DownloadOutcome`（交互模式拿进度条）；`pause()`（终止子进程，返回 `.paused`）；继续 = 再次 `start`；`cancel()`；`isRunning` |
| `DownloadRequest` | `appID` / `externalVersionID?` / `purchase` / `output`（文件路径或已存在目录）/ `platform?` |
| `DownloadEvent` / `DownloadOutcome` / `DownloadResult` | `.started` `.progress` `.log` `.verifying` `.finished` / `.completed` `.paused` `.cancelled` `.failed` / `fileURL` `purchased` `info` |
| `DownloadProgress` / `ProgressParser` | `fraction?` / `bytes` / `total?` / `bytesPerSecond?` / `source`（progressBar / tempFile）；`ProgressParser.parse(_:)` |
| `ZipReader` / `IPAInfo` | 原生读取 zip 中央目录（stored/deflate、ZIP64）；`IPAInfo.read(from:)` 取 `Payload/*.app/Info.plist` 的 bundle ID / 版本 |
| `IpatoolError` / `IpatoolErrorKind` / `IpatoolErrorMapper` | `kind` + `raw`（原始英文）+ `exitCode`；`message` 为中文文案（同 `errorDescription`）；`map(_:exitCode:)` |

## 接手须知

- 新环境：`brew install xcodegen` → `scripts/fetch-ipatool.sh` → `xcodegen generate`。`IPADepot.xcodeproj` 由 xcodegen 生成，不入库。
- 测试临时文件都在 `FileManager.default.temporaryDirectory/IPADepotCoreTests-<UUID>`，tearDown 时删除。
