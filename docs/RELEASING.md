# 发版步骤

适用于在本机（macOS 14+，Xcode 27.1，已安装 xcodegen）发布 IPA Depot。发布前须用户亲自验收。

## 0. 一次性准备

1. 确认 `vendor/ipatool/ipatool` 存在且与 `vendor/ipatool/VERSION` 的 sha256 一致；没有就运行 `scripts/fetch-ipatool.sh`。
2. 填写仓库 owner（只需做一次）：

   ```sh
   scripts/set-owner.sh <GitHub 用户名>
   ```

   脚本改写 `App/Logic/ProjectInfo.swift` 的 `repositoryOwner` 一行，并把 README 里的仓库链接换成新 owner；之后「关于」页的项目地址可点、「检查更新」可用。改完提交一次。

## 1. 改版本号

1. 编辑 `project.yml` 的 `MARKETING_VERSION`（例如 `0.1.1`）。`CFBundleVersion` 不用改，构建脚本会用 UTC 时间戳 `YYYYMMDDHHmm` 覆盖。
2. 在 `CHANGELOG.md` 把 `[Unreleased]` 下的内容移到新版本标题下，写上日期。
3. 提交：`git commit -am "release: 0.1.1"`。

## 2. 构建发布包

```sh
scripts/build-release.sh
```

脚本依次执行：`xcodegen generate` → universal Release 构建（arm64 + x86_64）→ 检查主程序、内置 ipatool、IPADepotCore 都是 universal → `codesign --force --deep -s -`（ad-hoc，无 Hardened Runtime）→ `codesign --verify --deep --strict` → zip（`ditto -c -k --keepParent`）→ dmg（`hdiutil`，含「应用程序」快捷方式）→ 各自的 `.sha256`。

产物在 `build/release/`：

- `IPA Depot.app`（已签名，本地验收用，不上传）
- `IPA-Depot-<版本>-macos-universal.zip` 与 `.zip.sha256`
- `IPA-Depot-<版本>-macos-universal.dmg` 与 `.dmg.sha256`

## 3. 本地验收

```sh
cd build/release
lipo -info "IPA Depot.app/Contents/MacOS/IPA Depot"           # 应含 x86_64 arm64
codesign --verify --deep --strict --verbose=2 "IPA Depot.app"  # valid on disk
codesign -dv "IPA Depot.app" 2>&1 | grep flags                 # flags=0x2(adhoc)，无 runtime
shasum -a 256 -c *.sha256                                      # 两个 OK
hdiutil verify IPA-Depot-*.dmg
```

`spctl -a -vv` 会显示 rejected，这是未公证的 ad-hoc 包的正常结果。

然后模拟用户安装：打开 dmg → 拖到「应用程序」→ 按 README「安装与首次打开」走一遍（仍要打开 → 准备页 → 登录 → 钥匙串「始终允许」→ 搜索 → 历史版本 → 下载一个小的免费 App）。

## 4. 打标签并发布（推荐：GitHub Actions）

```sh
git tag v0.1.1
git push origin main --tags
```

推送 `v*` 标签会触发 `.github/workflows/release.yml`：在 `macos-15` 上拉取 ipatool、运行 `scripts/build-release.sh`，并用 `softprops/action-gh-release` 把 zip、dmg、sha256 上传到一个 **Release 草稿**。到 GitHub 的 Releases 页面检查草稿，把 CHANGELOG 对应段落和 README「安装与首次打开」的要点贴进说明，确认后点「Publish release」。

注意：CI 构建出的包与本地构建的 sha256 不同（时间戳与签名不同），发布页以 CI 产物附带的 `.sha256` 为准。

## 5. 备用：手动上传

CI 不可用时，用本地 `build/release/` 的产物手动发布：

1. 打标签并推送：`git tag v0.1.1 && git push origin v0.1.1`。
2. 打开仓库的 **Releases › Draft a new release**，选择刚推送的标签，标题写 `IPA Depot 0.1.1`。
3. 把 `IPA-Depot-0.1.1-macos-universal.zip`、`.dmg` 和两个 `.sha256` 拖进附件区。
4. 说明里贴 CHANGELOG 对应段落与安装提示（「仍要打开」与 xattr 备用命令），点「Publish release」。

如果装了 GitHub CLI，也可以用：

```sh
gh release create v0.1.1 --draft --title "IPA Depot 0.1.1" --notes-file <说明文件> \
  build/release/IPA-Depot-0.1.1-macos-universal.zip build/release/IPA-Depot-0.1.1-macos-universal.dmg \
  build/release/*.sha256
```

## 6. 发布后

- 用旧版本的「设置 › 检查更新」确认能提示新版本（读取的是 GitHub Releases 的 latest，草稿与预发布不算）。
- 升级内置 ipatool 时：改 `scripts/fetch-ipatool.sh` 的 `VERSION`，重新运行，提交新的 `vendor/ipatool/VERSION` 与 `LICENSE`。用户升级后系统可能再次询问钥匙串授权，在 CHANGELOG 里注明。
