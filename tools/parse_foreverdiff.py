#!/usr/bin/env python3
"""Parse foreverdiff.com/waylaid-crates/ (client-data read of build 1.60.1.71091) into crates.json.
Usage: python3 parse_foreverdiff.py foreverdiff.html > crates.json"""
import re, sys, json, html
t = open(sys.argv[1], encoding='utf-8').read()
rows = re.split(r'<div class="wc-row" id="crate-(\d+)"', t)
crates = []
for k in range(1, len(rows), 2):
    cid, body = int(rows[k]), rows[k+1]
    body = body.split('<div class="wc-row"')[0]
    name = html.unescape(re.search(r'<a href="/items/[^"]*"[^>]*>([^<]+)</a>', body).group(1)).strip()
    meta = re.search(r'class="wc-meta dim"[^>]*>(.*?)</div>', body, re.S).group(1)
    meta = [html.unescape(x).strip() for x in re.sub(r'<[^>]+>', '', meta).replace('&middot;', '·').split('·')]
    ul = re.search(r'<ul class="wc-bundles".*?</ul>', body, re.S).group(0)
    bundles = []
    for li in re.findall(r'<li[^>]*>(.*?)</li>', ul, re.S):
        cnt = int(re.search(r'wc-count[^>]*>(\d+)<', li).group(1))
        m = re.search(r'href="/items/[^"]*?-(\d+)/"[^>]*>([^<]+)<', li)
        if m: iid, iname = int(m.group(1)), html.unescape(m.group(2)).strip()
        else:
            iid = None; iname = html.unescape(re.sub(r'<[^>]+>', '', li.split('</span>', 1)[1])).strip()
        bundles.append({'item': iid, 'name': iname, 'count': cnt})
    lvl = int(re.search(r'\d+', meta[1]).group(0)) if len(meta) > 1 else None
    crates.append({'id': cid, 'name': name, 'category': meta[0], 'level': lvl,
                   'quality': meta[2] if len(meta) > 2 else None, 'bundles': bundles})
seen = set(); out = []
for c in crates:
    if c['id'] not in seen: seen.add(c['id']); out.append(c)
json.dump(out, sys.stdout, indent=1)
