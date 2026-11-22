#!/bin/sh
# 把 libmpv 的 4 个 jar 补回 build 目录。
#
# 为什么需要这个：media_kit_libs_android_audio 的 build.gradle 会在构建时
# 从 GitHub 下载这几个 jar，国内网络经常超时，构建直接失败。
# 这里在 tools/media_kit_jars/ 存了一份，构建前补回去。
# flutter clean 会删掉 build/，所以这个脚本是每次构建的保险。
#
# 注意：**不能只判断"文件存在"**。下载超时会在目标位置留下 0 字节的残骸，
# 只判存在就会跳过；接着 gradle 校验 MD5 失败又去下载，再次超时——
# 表现就是"明明补了 jar 还是构建失败"。所以要比大小。
set -e
cd "$(dirname "$0")/.."

SRC="tools/media_kit_jars"
DST="build/media_kit_libs_android_audio/v1.1.8"

[ -d "$SRC" ] || exit 0
mkdir -p "$DST"

for f in "$SRC"/*.jar; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  src_size=$(wc -c < "$f")
  [ "$src_size" -gt 0 ] || continue

  if [ -f "$DST/$b" ]; then
    dst_size=$(wc -c < "$DST/$b")
    if [ "$dst_size" -eq "$src_size" ]; then
      continue
    fi
    echo "[jars] 大小不符，覆盖 $b（$dst_size → $src_size）"
  else
    echo "[jars] 补回 $b"
  fi
  cp "$f" "$DST/$b"
done
