#!/usr/bin/env bash
# Xcode 构建阶段：把 vendor/ipatool/ipatool 拷到 App 的 Contents/Resources/bin/ipatool，
# 校验 sha256 与 vendor/ipatool/VERSION 一致，保留可执行位并 ad-hoc 签名。
set -euo pipefail

SRC="${SRCROOT}/vendor/ipatool/ipatool"
VERSION_FILE="${SRCROOT}/vendor/ipatool/VERSION"
RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
DEST_DIR="${RES}/bin"
DEST="${DEST_DIR}/ipatool"

if [[ ! -f "${SRC}" ]]; then
  echo "error: 缺少 ${SRC}，请先运行 scripts/fetch-ipatool.sh"
  exit 1
fi

expected="$(awk '/lipo merged/ {print $NF}' "${VERSION_FILE}")"
actual="$(shasum -a 256 "${SRC}" | awk '{print $1}')"
if [[ -n "${expected}" && "${expected}" != "${actual}" ]]; then
  echo "error: vendor/ipatool/ipatool 的 sha256 (${actual}) 与 VERSION 记录 (${expected}) 不一致，请重新运行 scripts/fetch-ipatool.sh"
  exit 1
fi

mkdir -p "${DEST_DIR}"
/usr/bin/ditto "${SRC}" "${DEST}"
chmod 755 "${DEST}"
/usr/bin/codesign --force --sign - "${DEST}"
/usr/bin/ditto "${SRCROOT}/vendor/ipatool/LICENSE" "${RES}/ipatool-LICENSE"
echo "已内置 ipatool: ${DEST}"
