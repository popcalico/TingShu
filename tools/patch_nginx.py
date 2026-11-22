#!/usr/bin/env python3
"""在阿里云 ECS 的主机 nginx 上，为 ali.popcalico.top 的 443 块挂一个 /tingshu/ 反代。

踩过的坑（写在这里避免下次重犯）：
1. /etc/nginx/sites-enabled/*.conf 全是**符号链接**，指向 sites-available/。
   `cp -a` 备份会保留链接属性，于是 sites-enabled 里多出一个指向同一文件的链接，
   而 nginx.conf 的 include 是 `sites-enabled/*`（通配，不看后缀），
   结果同一份配置被加载两次 → `duplicate default server for 0.0.0.0:5660`。
   → 备份必须解引用（cp -L）并放到目录外。
2. 临时文件绝不能写在 sites-enabled/ 里，同样会被 include。
"""
import os
import sys
import paramiko
import time

HOST = os.environ.get("TS_HOST", "")
USER = os.environ.get("TS_USER", "root")
PWD = os.environ.get("TS_PWD", "")
if not HOST or not PWD:
    sys.exit("缺少凭据：export TS_HOST=服务器地址 TS_PWD=root密码")
LINK = "/etc/nginx/sites-enabled/frp-nas.conf"
REAL = "/etc/nginx/sites-available/frp-nas.conf"   # 符号链接的真实目标
TMP = "/tmp/frp-nas.conf.new"

SNIPPET = """    # ---- 听评书 App 更新（Docker 容器 tingshu-update，仅监听本机 8765）----
    # 用子路径而非新端口/新子域名：复用本域名的 *.popcalico.top 泛域名证书，
    # 不用改阿里云 DNS，也不用开安全组端口。
    location /tingshu/ {
        proxy_pass http://127.0.0.1:8765/;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # 静态大文件开缓冲；server 级默认 off 是给视频流用的
        proxy_buffering on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        client_max_body_size 0;
    }
"""

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PWD, timeout=25)


def run(cmd):
    _i, o, e = c.exec_command(cmd, timeout=60)
    return o.read().decode(errors="replace").strip(), e.read().decode(errors="replace").strip()


sftp = c.open_sftp()
original = sftp.open(REAL, "r").read().decode("utf-8")

if "/tingshu/" in original:
    print("已存在 /tingshu/ 配置，跳过插入")
else:
    out, in443, inserted = [], False, False
    for ln in original.split("\n"):
        if "listen 443 ssl" in ln:
            in443 = True
        if in443 and not inserted and ln.strip() == "location / {":
            out.append(SNIPPET.rstrip("\n"))
            inserted = True
        out.append(ln)
    if not inserted:
        raise SystemExit("没找到 443 块里的 location /，放弃修改（未做任何变更）")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    print(run(f"mkdir -p /root/nginx-backup && cp -L {REAL} /root/nginx-backup/frp-nas.conf.{stamp} && echo ok")[0])

    with sftp.open(TMP, "w") as f:
        f.write("\n".join(out))
    sftp.close()

    # 覆盖真实文件（不碰符号链接本身）
    print(run(f"cp {TMP} {REAL} && nginx -t")[0])
    ok, err = run("nginx -t")
    print(ok, err)
    if "successful" not in (ok + err):
        run(f"cp -L /root/nginx-backup/frp-nas.conf.{stamp} {REAL} && nginx -t")
        raise SystemExit("nginx -t 未通过，已回滚")
    run("systemctl reload nginx || nginx -s reload")
    print("已 reload nginx")

print(run("ls /etc/nginx/sites-enabled/")[0])
print(run("curl -s -o /dev/null -w 'https version.json: %{http_code}\\n' https://ali.popcalico.top/tingshu/version.json")[0])
print(run("curl -s -o /dev/null -w 'https apk range: %{http_code}\\n' -r 0-99 https://ali.popcalico.top/tingshu/tingshu.apk")[0])
print(run("curl -s https://ali.popcalico.top/tingshu/version.json | head -3")[0])
c.close()
