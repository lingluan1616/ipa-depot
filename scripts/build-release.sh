#!/usr/bin/env bash
# 构建 IPA Depot 发布包：universal（arm64 + x86_64）Release 构建 → ad-hoc 签名 → zip + dmg + sha256。
# 产物：build/release/IPA Depot.app、IPA-Depot-<版本>-macos-universal.{zip,dmg}、对应 .sha256
# 版本号读 project.yml 的 MARKETING_VERSION；CFBundleVersion 用 UTC 时间戳 YYYYMMDDHHmm。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

APP_NAME="IPA Depot"
DERIVED="${ROOT}/build/DerivedData"
OUT="${ROOT}/build/release"

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
if [[ -z "${VERSION}" ]]; then
  echo "error: 无法从 project.yml 读取 MARKETING_VERSION" >&2
  exit 1
fi
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
BASENAME="IPA-Depot-${VERSION}-macos-universal"
echo "==> IPA Depot ${VERSION}（build ${BUILD_NUMBER}）"

if [[ ! -x "${ROOT}/vendor/ipatool/ipatool" ]]; then
  echo "error: 缺少 vendor/ipatool/ipatool，请先运行 scripts/fetch-ipatool.sh" >&2
  exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen generate"
  xcodegen generate --quiet
elif [[ ! -d "${ROOT}/IPADepot.xcodeproj" ]]; then
  echo "error: 找不到 IPADepot.xcodeproj，且未安装 xcodegen（brew install xcodegen）" >&2
  exit 1
fi

echo "==> xcodebuild Release（arm64 + x86_64）"
xcodebuild -scheme IPADepot -configuration Release -derivedDataPath "${DERIVED}" \
  -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  build

BUILT_APP="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "error: 构建产物不存在：${BUILT_APP}" >&2
  exit 1
fi

# 清空上次的产物（只动 build/release）
/bin/rm -rf -- "${OUT}"
mkdir -p "${OUT}"
APP="${OUT}/${APP_NAME}.app"
/usr/bin/ditto "${BUILT_APP}" "${APP}"

echo "==> 检查架构"
EXE="${APP}/Contents/MacOS/${APP_NAME}"
for bin in "${EXE}" "${APP}/Contents/Resources/bin/ipatool" "${APP}/Contents/Frameworks/IPADepotCore.framework/IPADepotCore"; do
  info="$(lipo -info "${bin}")"
  echo "    ${info}"
  if [[ "${info}" != *arm64* || "${info}" != *x86_64* ]]; then
    echo "error: 不是 universal：${bin}" >&2
    exit 1
  fi
done

echo "==> ad-hoc 签名（无 Hardened Runtime）"
/usr/bin/codesign --force --deep --sign - "${APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP}"

PLIST="${APP}/Contents/Info.plist"
echo "    CFBundleShortVersionString=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
echo "    CFBundleVersion=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"

echo "==> zip"
/usr/bin/ditto -c -k --keepParent "${APP}" "${OUT}/${BASENAME}.zip"

echo "==> dmg"
STAGING="$(mktemp -d "${ROOT}/build/dmg-staging.XXXXXX")"
cleanup() { /bin/rm -rf -- "${STAGING}"; }
trap cleanup EXIT
/usr/bin/ditto "${APP}" "${STAGING}/${APP_NAME}.app"
ln -s /Applications "${STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov -format UDZO "${OUT}/${BASENAME}.dmg"

echo "==> sha256"
(
  cd "${OUT}"
  for f in "${BASENAME}.zip" "${BASENAME}.dmg"; do
    shasum -a 256 "${f}" > "${f}.sha256"
    cat "${f}.sha256"
  done
)

echo "==> 完成：${OUT}"
ls -l "${OUT}"
