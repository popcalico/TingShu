#!/usr/bin/env bash
# 一键发布：构建 APK → 校验版本号 → 生成清单 → 推到服务器
#
# 用法：
#   ./tools/publish.sh "这次改了什么"            # 推【测试版】beta（默认）
#   ./tools/publish.sh "这次改了什么" --stable   # 推【标准版】stable（正式）
#   ./tools/publish.sh "这次改了什么" --both     # 两条线同时推（同一个包）
#   ./tools/publish.sh "说明" --no-deploy       # 只构建，不发布
#
# 什么时候用 --both：
#   1) 基线对齐：旧版客户端只认标准线，必须先让标准线升到"带双通道的版本"，
#      手机才可能看到测试线。
#   2) 测试版验证稳定后"转正"：同一个包两边都放，用户的 beta 设备不会被降级。
#
# 两条线互不影响：
#   beta   → version-beta.json + tingshu-beta.apk   自己的设备
#   stable → version.json      + tingshu.apk        家里老人的设备
#
# **默认 beta**：没有明确指示不要动标准版，避免老人手机频繁弹更新。
#
# 发布前记得改 pubspec.yaml 的 build number（version: 1.1.6+10 里的 10）。
# 两条线共用同一个 versionCode 序列，beta 的号永远 >= stable 的号，
# 这样从 beta 切回 stable 不会出现"被降级"的提示。
#
# 注意：**不要用 --split-per-abi**。
# Flutter 会给按 ABI 拆分的包改写 versionCode（v7a=1001、arm64=2001、x86_64=4001），
# 和通用包对不上，自动更新会永远判断"没有新版本"或者装不上。

set -euo pipefail

NOTES="${1:-日常更新}"
shift || true

CHANNEL="beta"
DEPLOY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --stable) CHANNEL="stable" ;;
    --beta) CHANNEL="beta" ;;
    --both) CHANNEL="both" ;;
    --no-deploy) DEPLOY=0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."

VERSION_LINE=$(grep -E '^version:' pubspec.yaml | head -1 | sed 's/version:[[:space:]]*//')
VERSION_NAME="${VERSION_LINE%%+*}"
VERSION_CODE="${VERSION_LINE##*+}"

if [ "$VERSION_NAME" = "$VERSION_CODE" ]; then
  echo "pubspec.yaml 里要有 build number，例如 version: 1.0.2+3"
  exit 1
fi

echo "==> 构建 听评书 ${VERSION_NAME} (${VERSION_CODE}) → 通道 ${CHANNEL}"
source ./env.sh 2>/dev/null || source ../env.sh 2>/dev/null || true
# libmpv 的 jar 靠 GitHub 下载，国内常超时；先补回本地备份
sh tools/ensure_media_kit_jars.sh
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK" ] || { echo "构建产物不存在: $APK"; exit 1; }

REAL_CODE=$("D:/AndroidSdk/build-tools/36.1.0/aapt2.exe" dump badging "$APK" 2>/dev/null \
  | grep -o "versionCode='[0-9]*'" | head -1 | grep -o "[0-9]*")
if [ "$REAL_CODE" != "$VERSION_CODE" ]; then
  echo "版本号不一致：pubspec=$VERSION_CODE，APK=$REAL_CODE"
  echo "多半是构建用了 --split-per-abi。请用 flutter build apk --release 重新构建。"
  exit 1
fi

mkdir -p server
SIZE=$(stat -c %s "$APK")

# 要写哪几条清单
if [ "$CHANNEL" = "both" ]; then
  TARGETS="stable beta"
else
  TARGETS="$CHANNEL"
fi

for ch in $TARGETS; do
  if [ "$ch" = "beta" ]; then
    MANIFEST="server/version-beta.json"
    APK_NAME="tingshu-beta.apk"
  else
    MANIFEST="server/version.json"
    APK_NAME="tingshu.apk"
  fi

  python - "$VERSION_CODE" "$VERSION_NAME" "$SIZE" "$APK_NAME" "$NOTES" "$MANIFEST" <<'PY'
import json, sys
code, name, size, apk_name, notes, path = sys.argv[1:7]
data = {
    "versionCode": int(code),
    "versionName": name,
    "url": f"https://ali.popcalico.top/tingshu/{apk_name}",
    "size": int(size),
    "notes": notes,
    "force": False,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(json.dumps(data, ensure_ascii=False, indent=2))
PY

  echo
  echo "==> 已生成 ${MANIFEST}（${SIZE} bytes）"
done

if [ "$DEPLOY" = "1" ]; then
  for ch in $TARGETS; do
    echo "==> 上传到服务器（${ch} 线）"
    python tools/deploy_server.py --${ch}
  done
else
  echo "==> 已跳过上传（--no-deploy）"
fi
