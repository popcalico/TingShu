import base64
import os
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

NAS_USER = os.environ.get('TS_NAS_USER', '')
NAS_PASS = os.environ.get('TS_NAS_PASS', '')
NAS_URL = os.environ.get('TS_NAS_URL', '')
if not (NAS_USER and NAS_PASS and NAS_URL):
    sys.exit('缺少参数：export TS_NAS_URL / TS_NAS_USER / TS_NAS_PASS')

AUTH = 'Basic ' + base64.b64encode(f'{NAS_USER}:{NAS_PASS}'.encode()).decode()
BASE = NAS_URL.rstrip('/')
BODY = (b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
        b'<d:displayname/><d:resourcetype/><d:getcontentlength/>'
        b'</d:prop></d:propfind>')

lines = 0


def listdir(path):
    req = urllib.request.Request(
        BASE + path, data=BODY, method='PROPFIND',
        headers={'Authorization': AUTH, 'Depth': '1',
                 'Content-Type': 'application/xml'})
    with urllib.request.urlopen(req, timeout=40) as r:
        return r.read()


def parse(xml):
    root = ET.fromstring(xml)
    out = []
    for resp in root:
        href = None
        isdir = False
        size = 0
        for el in resp.iter():
            tag = el.tag.split('}')[-1]
            if tag == 'href' and href is None:
                href = (el.text or '').strip()
            elif tag == 'collection':
                isdir = True
            elif tag == 'getcontentlength' and el.text:
                try:
                    size = int(el.text)
                except ValueError:
                    size = 0
        if href:
            out.append((href, isdir, size))
    return out


def walk(path, depth, prefix, maxdepth):
    global lines
    if depth > maxdepth or lines > 400:
        return
    try:
        items = parse(listdir(path))
    except Exception as e:
        print(prefix + '!! ' + str(e))
        return
    for href, isdir, size in items:
        if urllib.parse.unquote(href).rstrip('/') == urllib.parse.unquote(path).rstrip('/'):
            continue
        name = urllib.parse.unquote(href.rstrip('/').split('/')[-1])
        lines += 1
        if lines > 400:
            print(prefix + '... (超过 400 行，截断)')
            return
        if isdir:
            print(prefix + '[D] ' + name + '/')
            walk(href, depth + 1, prefix + '  ', maxdepth)
        else:
            ext = name.rsplit('.', 1)[-1].lower() if '.' in name else ''
            mark = 'AUDIO' if ext in {
                'mp3', 'm4a', 'm4b', 'aac', 'wav', 'flac', 'ogg', 'wma', 'ape', 'amr'} else 'file'
            print(prefix + '    ' + name + '  [' + mark + ' ' + str(size) + ']')


start = sys.argv[1] if len(sys.argv) > 1 else '/book/'
depth = int(sys.argv[2]) if len(sys.argv) > 2 else 4
walk(start, 0, '', depth)
