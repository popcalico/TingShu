#!/usr/bin/env python3
"""听评书更新服务器部署脚本

用法（在本机工程根目录执行）：
    export TS_HOST=你的服务器地址
    export TS_PWD=你的 root 密码        # 或用 SSH 密钥，见下
    python tools/deploy_server.py --beta     # 推测试版（默认）
    python tools/deploy_server.py --stable   # 推标准版

两条线在服务器上完全独立：
    www/version.json        → www/tingshu.apk        标准版（家里老人用）
    www/version-beta.json   → www/tingshu-beta.apk   测试版（自己的设备）

设计说明：
- 容器只监听 127.0.0.1:8765，外网统一走主机 nginx 的 /tingshu/ 反代，
  复用已有的泛域名证书，不需要额外开端口、不需要改 DNS。
- 换版本只覆盖文件，不动 nginx。

**凭据一律从环境变量读，脚本里不写任何密码**——
这个文件是要进公开仓库的。
"""
import os
import sys
import paramiko

HOST = os.environ.get("TS_HOST", "")
USER = os.environ.get("TS_USER", "root")
PWD = os.environ.get("TS_PWD", "")
# 支持免密：TS_KEY 指向私钥文件时优先用密钥，不用密码
KEY = os.environ.get("TS_KEY", "")
REMOTE = "/opt/tingshu"

if not HOST:
    sys.exit("缺少 TS_HOST：先 export TS_HOST=你的服务器地址")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def connect():
    if not PWD and not KEY:
        sys.exit("缺少凭据：export TS_PWD=密码，或者 TS_KEY=私钥文件路径")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kw = dict(port=22, username=USER, timeout=25, banner_timeout=25, auth_timeout=25)
    if KEY:
        kw["key_filename"] = KEY
    else:
        kw["password"] = PWD
    c.connect(HOST, **kw)
    return c


def run(c, cmd):
    _i, o, e = c.exec_command(cmd, timeout=120)
    out = o.read().decode(errors="replace").rstrip()
    err = e.read().decode(errors="replace").rstrip()
    code = o.channel.recv_exit_status()
    if out:
        print(out)
    if err:
        print("[stderr]", err)
    if code != 0:
        raise SystemExit(f"命令失败(code={code}): {cmd}")
    return out


def main():
    beta = "--stable" not in sys.argv
    tag = "beta" if beta else "stable"

    apk_local = os.path.join(ROOT, "build", "app", "outputs", "flutter-apk", "app-release.apk")
    manifest_local = os.path.join(ROOT, "server", "version-beta.json" if beta else "version.json")

    if not os.path.exists(apk_local):
        raise SystemExit(f"找不到构建产物：{apk_local}（先 flutter build apk --release）")
    if not os.path.exists(manifest_local):
        raise SystemExit(f"找不到清单：{manifest_local}（先跑 tools/publish.sh）")

    apk_name = "tingshu-beta.apk" if beta else "tingshu.apk"
    manifest_name = "version-beta.json" if beta else "version.json"

    c = connect()
    sftp = c.open_sftp()
    run(c, f"mkdir -p {REMOTE}/www")

    # 容器定义（两条线共用，每次覆盖也无副作用）
    for name in ("docker-compose.yml", "nginx.conf"):
        sftp.put(os.path.join(ROOT, "server", name), f"{REMOTE}/{name}")
    print(f"[up] docker-compose.yml / nginx.conf")

    size = os.path.getsize(apk_local)
    print(f"[up] {apk_name} ({size/1048576:.1f}MB) → 通道 {tag}，请稍候…")
    sftp.put(apk_local, f"{REMOTE}/www/{apk_name}")
    sftp.put(manifest_local, f"{REMOTE}/www/{manifest_name}")
    sftp.close()
    print(f"[up] www/{manifest_name}")

    run(c, f"cd {REMOTE} && docker compose up -d")
    run(c, "docker ps --filter name=tingshu-update --format '{{.Names}} {{.Status}}'")

    base = "https://ali.popcalico.top/tingshu"
    for f in (manifest_name, apk_name):
        run(c, f"curl -s -o /dev/null -w '{f}: %{{http_code}}\\n' {base}/{f}")
    run(c, f"curl -s -o /dev/null -w '{apk_name} range: %{{http_code}}\\n' -r 0-99 {base}/{apk_name}")

    c.close()
    print(f"\n完成。{tag} 线：{base}/{manifest_name}")


if __name__ == "__main__":
    main()
