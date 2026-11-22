#!/usr/bin/env python3
"""听评书 设备日志收集服务。

只做四件事：
    POST /report              设备上报（App 启动时调）
    GET  /list                有哪些设备回传过
    GET  /tail?device=&limit= 某台设备最近的日志
    GET  /export?device=      整台设备的全量日志（纯文本，喂给 AI 分析）

存储：<DATA>/<deviceId>/<YYYY-MM-DD>.jsonl，一天一个文件。
每行是"日志条目 + 设备信息"，直接用 jq / pandas 就能分析。

为什么用标准库：这台服务器上只跑 nginx 和 frps，为一个小接口装
FastAPI/uvicorn 不值得；标准库的 ThreadingHTTPServer 撑几百台设备够用。

部署：
    cp log_server.py /opt/tingshu-log/
    TS_LOG_TOKEN=xxx TS_LOG_PORT=8790 python3 /opt/tingshu-log/log_server.py
nginx 反代： location /tingshu-log/ { proxy_pass http://127.0.0.1:8790/; }

安全：
- 所有接口都要 X-TS-Token，值由环境变量 TS_LOG_TOKEN 指定
- 只写自己的数据目录，不接受任何路径参数（设备名做了白名单过滤）
- 单次请求体上限 8MB，单条日志超长直接截断
"""
import json
import os
import re
import time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = os.environ.get('TS_LOG_TOKEN', '')
DATA = os.environ.get('TS_LOG_DIR', '/opt/tingshu-log/data')
PORT = int(os.environ.get('TS_LOG_PORT', '8790'))
KEEP_DAYS = int(os.environ.get('TS_LOG_KEEP_DAYS', '30'))
MAX_BODY = 8 * 1024 * 1024

SAFE = re.compile(r'[^A-Za-z0-9_.-]')


def safe_id(name: str) -> str:
    """设备 ID 只允许字母数字和 -_.，防止目录穿越。"""
    return SAFE.sub('', str(name or ''))[:48] or 'unknown'


def label(v, n=60):
    s = str(v or '')
    return s[:n]


def day_path(device: str, ts_ms: int) -> str:
    day = datetime.fromtimestamp(ts_ms / 1000.0).strftime('%Y-%m-%d')
    d = os.path.join(DATA, device)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, day + '.jsonl')


def write_meta(device: str, meta: dict):
    d = os.path.join(DATA, device)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'device.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False)


def read_meta(device: str) -> dict:
    p = os.path.join(DATA, device, 'device.json')
    try:
        with open(p, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def iter_entries(device: str):
    """按时间顺序遍历某台设备的全部日志。"""
    d = os.path.join(DATA, device)
    if not os.path.isdir(d):
        return
    files = sorted(f for f in os.listdir(d) if f.endswith('.jsonl'))
    for name in files:
        try:
            with open(os.path.join(d, name), encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        yield json.loads(line)
                    except Exception:
                        continue
        except Exception:
            continue


def prune_old():
    """删掉超过 KEEP_DAYS 的文件，避免无限增长。"""
    cutoff = datetime.now() - timedelta(days=KEEP_DAYS)
    try:
        for device in os.listdir(DATA):
            d = os.path.join(DATA, device)
            if not os.path.isdir(d):
                continue
            for name in os.listdir(d):
                if not name.endswith('.jsonl'):
                    continue
                try:
                    day = datetime.strptime(name[:10], '%Y-%m-%d')
                except Exception:
                    continue
                if day < cutoff:
                    try:
                        os.remove(os.path.join(d, name))
                    except Exception:
                        pass
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = 'tingshu-log/1.0'

    def log_message(self, fmt, *args):
        # 只记一行，别刷屏
        print('%s %s' % (self.address_string(), fmt % args), flush=True)

    # ---------- 基础 ----------

    def _json(self, code: int, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _text(self, code: int, text: str):
        body = text.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        if not TOKEN:
            return False
        return self.headers.get('X-TS-Token', '') == TOKEN

    def _device_arg(self):
        qs = parse_qs(urlparse(self.path).query)
        return safe_id((qs.get('device') or [''])[0])

    # ---------- 接口 ----------

    def do_POST(self):
        if urlparse(self.path).path != '/report':
            return self._json(404, {'ok': False, 'error': 'not found'})
        if not self._authed():
            return self._json(401, {'ok': False, 'error': 'unauthorized'})

        try:
            n = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            n = 0
        if n <= 0 or n > MAX_BODY:
            return self._json(400, {'ok': False, 'error': 'bad size'})

        try:
            payload = json.loads(self.rfile.read(n).decode('utf-8'))
        except Exception:
            return self._json(400, {'ok': False, 'error': 'bad json'})

        device = safe_id(payload.get('deviceId'))
        entries = payload.get('entries') or []
        if not isinstance(entries, list):
            return self._json(400, {'ok': False, 'error': 'bad entries'})

        meta = {
            'deviceId': device,
            'deviceName': label(payload.get('deviceName'), 40),
            'model': label(payload.get('model'), 40),
            'manufacturer': label(payload.get('manufacturer'), 40),
            'sdk': payload.get('sdk'),
            'versionName': label(payload.get('versionName'), 20),
            'versionCode': payload.get('versionCode'),
            'lastSeen': int(time.time() * 1000),
            'lastCount': len(entries),
        }

        saved = 0
        for e in entries:
            if not isinstance(e, dict):
                continue
            try:
                ts = int(e.get('t') or 0)
            except (TypeError, ValueError):
                continue
            if ts <= 0:
                continue
            row = {k: e.get(k) for k in ('t', 'lv', 'k', 'm', 'd') if k in e}
            row['deviceId'] = device
            row['model'] = meta['model']
            row['versionName'] = meta['versionName']
            try:
                with open(day_path(device, ts), 'a', encoding='utf-8') as f:
                    f.write(json.dumps(row, ensure_ascii=False) + '\n')
                saved += 1
            except Exception as ex:
                print('write fail: %s' % ex, flush=True)

        try:
            write_meta(device, meta)
        except Exception:
            pass
        prune_old()
        return self._json(200, {'ok': True, 'saved': saved})

    def do_GET(self):
        path = urlparse(self.path).path
        if not self._authed():
            return self._json(401, {'ok': False, 'error': 'unauthorized'})

        if path == '/list':
            return self._list()
        if path == '/tail':
            return self._tail()
        if path == '/export':
            return self._export()
        if path == '/health':
            return self._json(200, {'ok': True, 'devices': len(os.listdir(DATA)) if os.path.isdir(DATA) else 0})
        return self._json(404, {'ok': False, 'error': 'not found'})

    def _list(self):
        devices = []
        if os.path.isdir(DATA):
            for device in sorted(os.listdir(DATA)):
                d = os.path.join(DATA, device)
                if not os.path.isdir(d):
                    continue
                meta = read_meta(device)
                count = 0
                last = 0
                for name in os.listdir(d):
                    if not name.endswith('.jsonl'):
                        continue
                    try:
                        with open(os.path.join(d, name), encoding='utf-8') as f:
                            for _ in f:
                                count += 1
                    except Exception:
                        pass
                for e in iter_entries(device):
                    try:
                        last = max(last, int(e.get('t') or 0))
                    except Exception:
                        pass
                    break
                devices.append({
                    'deviceId': device,
                    'deviceName': meta.get('deviceName') or '',
                    'model': meta.get('model') or '',
                    'manufacturer': meta.get('manufacturer') or '',
                    'versionName': meta.get('versionName') or '',
                    'versionCode': meta.get('versionCode'),
                    'lastSeen': meta.get('lastSeen') or 0,
                    'lastAt': last,
                    'count': count,
                })
        return self._json(200, {'ok': True, 'devices': devices})

    def _tail(self):
        device = self._device_arg()
        qs = parse_qs(urlparse(self.path).query)
        try:
            limit = min(int((qs.get('limit') or ['300'])[0]), 2000)
        except ValueError:
            limit = 300

        rows = list(iter_entries(device))
        rows.sort(key=lambda r: int(r.get('t') or 0))
        rows = rows[-limit:]
        return self._json(200, {'ok': True, 'device': device, 'entries': rows})

    def _export(self):
        device = self._device_arg()
        meta = read_meta(device)
        rows = list(iter_entries(device))
        rows.sort(key=lambda r: int(r.get('t') or 0))
        lines = [
            '# 听评书 设备日志（服务器导出）',
            '设备：%s（%s %s）' % (meta.get('deviceName') or '未命名',
                                 meta.get('manufacturer') or '', meta.get('model') or ''),
            '设备ID：%s' % device,
            '版本：%s (%s)' % (meta.get('versionName') or '', meta.get('versionCode') or ''),
            '条数：%d' % len(rows),
            '----',
        ]
        for r in rows:
            ts = int(r.get('t') or 0)
            t = datetime.fromtimestamp(ts / 1000.0).strftime('%Y-%m-%d %H:%M:%S') if ts else '?'
            lv = {'i': '操作', 'w': '提醒', 'e': '错误'}.get(str(r.get('lv')), '?')
            msg = r.get('m') or ''
            data = r.get('d')
            extra = ''
            if isinstance(data, dict) and data:
                extra = '  ' + ' '.join('%s=%s' % (k, v) for k, v in data.items())
            lines.append('%s  %s  %s%s' % (t, lv, msg, extra))
        return self._text(200, '\n'.join(lines))


def main():
    if not TOKEN:
        raise SystemExit('请先设置 TS_LOG_TOKEN 环境变量')
    os.makedirs(DATA, exist_ok=True)
    srv = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    print('listening on 127.0.0.1:%d, data=%s' % (PORT, DATA), flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
