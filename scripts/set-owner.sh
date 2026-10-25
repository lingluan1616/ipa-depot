#!/usr/bin/env bash
# 一键填写 GitHub 仓库 owner：
#   scripts/set-owner.sh <GitHub 用户名>
# 改写 App/Logic/ProjectInfo.swift 的 repositoryOwner 一行，并把 README.md 里 github.com/<旧 owner>/ipa-depot 的链接换成新 owner。
# 可重复执行（以 ProjectInfo.swift 里的当前值为旧 owner）。初始占位值为 OWNER_PLACEHOLDER。
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "用法：$0 <GitHub 用户名>" >&2
  exit 2
fi
NEW="$1"
# GitHub 用户名：字母数字与连字符，1–39 位，不以连字符开头或结尾
if [[ ! "${NEW}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
  echo "error: 不是合法的 GitHub 用户名：${NEW}" >&2
  exit 2
fi

ROOT="${IPADEPOT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SWIFT="${ROOT}/App/Logic/ProjectInfo.swift"
README="${ROOT}/README.md"

OLD="$(sed -nE 's/^[[:space:]]*static let repositoryOwner = "([^"]*)".*/\1/p' "${SWIFT}")"
if [[ -z "${OLD}" ]]; then
  echo "error: 在 ${SWIFT} 里找不到 repositoryOwner" >&2
  exit 1
fi

sed -i '' -E "s/^([[:space:]]*static let repositoryOwner = \")[^\"]*(\".*)$/\1${NEW}\2/" "${SWIFT}"
sed -i '' "s#github.com/${OLD}/ipa-depot#github.com/${NEW}/ipa-depot#g" "${README}"

echo "repositoryOwner: ${OLD} → ${NEW}"
grep -n "static let repositoryOwner" "${SWIFT}"
echo "README 中的仓库链接："
grep -n "github.com/${NEW}/ipa-depot" "${README}" || echo "（README 中没有仓库链接）"
