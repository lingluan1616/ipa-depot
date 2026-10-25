#!/usr/bin/env bash
# 拉取 ipatool 官方 Release 二进制（arm64 + amd64），校验 sha256，lipo 合并为 universal。
# 产物：vendor/ipatool/ipatool、vendor/ipatool/LICENSE、vendor/ipatool/VERSION
# 下载缓存：build/downloads/（.gitignore 忽略）；解压目录：build/extract-<时间戳>/（用完删除）
set -euo pipefail

VERSION="2.7.0"
BASE_URL="https://github.com/majd/ipatool/releases/download/v${VERSION}"
LICENSE_URL="https://raw.githubusercontent.com/majd/ipatool/v${VERSION}/LICENSE"
ARCHES=(arm64 amd64)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DL_DIR="${ROOT}/build/downloads"
OUT_DIR="${ROOT}/vendor/ipatool"
EXTRACT_DIR="${ROOT}/build/extract-$(date +%Y%m%d%H%M%S)-$$"

mkdir -p "${DL_DIR}" "${OUT_DIR}" "${EXTRACT_DIR}"
cleanup() { /bin/rm -rf -- "${EXTRACT_DIR}"; }
trap cleanup EXIT

fetch() { # url dest
  local url="$1" dest="$2"
  if [[ -s "${dest}" ]]; then
    echo "已存在，跳过下载: ${dest##*/}"
  else
    echo "下载: ${url}"
    curl -fsSL --retry 3 --retry-delay 2 -o "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
  fi
}

declare -a THIN_BINS=()
declare -a SUM_LINES=()
for arch in "${ARCHES[@]}"; do
  pkg="ipatool-${VERSION}-macos-${arch}.tar.gz"
  fetch "${BASE_URL}/${pkg}" "${DL_DIR}/${pkg}"
  fetch "${BASE_URL}/${pkg}.sha256sum" "${DL_DIR}/${pkg}.sha256sum"

  expected="$(awk '{print $1; exit}' "${DL_DIR}/${pkg}.sha256sum" | tr 'A-F' 'a-f')"
  actual="$(shasum -a 256 "${DL_DIR}/${pkg}" | awk '{print $1}')"
  if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
    echo "sha256 校验失败: ${pkg}" >&2
    echo "  期望: ${expected}" >&2
    echo "  实际: ${actual}" >&2
    /bin/rm -f -- "${DL_DIR}/${pkg}"
    exit 1
  fi
  echo "sha256 校验通过: ${pkg} ${actual}"
  SUM_LINES+=("${pkg} ${actual}")

  dest="${EXTRACT_DIR}/${arch}"
  mkdir -p "${dest}"
  # 只解出普通文件，不执行包内任何脚本
  tar -xzf "${DL_DIR}/${pkg}" -C "${dest}"
  bin="$(find "${dest}" -type f -name 'ipatool*' ! -name '*.tar.gz' | head -n 1)"
  if [[ -z "${bin}" ]]; then
    echo "解压后找不到 ipatool 可执行文件: ${pkg}" >&2
    exit 1
  fi
  THIN_BINS+=("${bin}")
done

lipo -create "${THIN_BINS[@]}" -output "${OUT_DIR}/ipatool"
chmod 755 "${OUT_DIR}/ipatool"
lipo -info "${OUT_DIR}/ipatool"

curl -fsSL --retry 3 -o "${OUT_DIR}/LICENSE" "${LICENSE_URL}"

merged="$(shasum -a 256 "${OUT_DIR}/ipatool" | awk '{print $1}')"
{
  echo "ipatool ${VERSION}"
  echo "source: ${BASE_URL}/"
  for line in "${SUM_LINES[@]}"; do echo "sha256 ${line}"; done
  echo "sha256 ipatool(universal, lipo merged) ${merged}"
} > "${OUT_DIR}/VERSION"

cat "${OUT_DIR}/VERSION"
echo "完成: ${OUT_DIR}/ipatool"
