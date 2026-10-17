# -*- coding: utf-8 -*-
"""Deep string/metadata extraction for yimi-v13.dylib (disguised libCoreMediaAssist)"""
import lief, re, io
from collections import Counter

buf = io.StringIO()
def p(*a):
    s = " ".join(str(x) for x in a)
    buf.write(s + "\n")

TARGET = r"E:\WorkBuddy\2026-10-17-16-34-44\target.dylib"
raw = open(TARGET, "rb").read()
b = lief.parse(TARGET)

def section_bytes(name):
    for seg in b.segments:
        for s in seg.sections:
            if s.name == "__" + name or s.name == name:
                return raw[s.offset:s.offset + s.size], s
    return None, None

def cstrings(blob):
    out, cur = [], bytearray()
    for ch in blob:
        if ch == 0:
            if 3 <= len(cur) <= 200:
                out.append(cur.decode("latin-1"))
            cur = bytearray()
        else:
            cur.append(ch)
    if 3 <= len(cur) <= 200:
        out.append(cur.decode("latin-1"))
    return out

# ---------- 1. tweak's own ObjC class names ----------
blob, sec = section_bytes("objc_classname")
names = cstrings(blob) if blob else []
p("=== __objc_classname: %d classes ===" % len(names))
for n in names:
    p(n)

# ---------- 2. selectors ----------
blob, sec = section_bytes("objc_methname")
sels = cstrings(blob) if blob else []
p("\n=== __objc_methname: %d selectors ===" % len(sels))
KEY = ("vip", "VIP", "watermark", "Watermark", "download", "Download", "hook", "Hook", "pay", "Pay",
       "会员", "视频", "下载", "水印", "破解", "付费", "购买", "价格", "订阅", "登录", "缓存", "清晰度",
       "url", "URL", "http", "Http", "camera", "Camera", "album", "Album", "photo", "Photo",
       "export", "Export", "save", "Save", "share", "Share", "copy", "Copy", "paste", "Paste",
       "websocket", "WebSocket", "token", "Token", "auth", "Auth", "order", "Order", "license", "License",
       "free", "Free", "unlock", "Unlock", "pro", "Pro", "premium", "Premium", "reward", "Reward",
       "ad", "Ad", " Ad", "coin", "Coin", "balance", "Balance", "recharge", "Recharge")
hit = [s for s in sels if any(k in s for k in KEY)]
p("--- interesting selectors (%d) ---" % len(hit))
for s in sorted(set(hit)):
    p(s)
p("--- all selectors sample (first 120) ---")
for s in sels[:120]:
    p(s)

# ---------- 3. cstring mining ----------
blob, sec = section_bytes("cstring")
cs = cstrings(blob) if blob else []
p("\n=== __cstring: %d strings ===" % len(cs))

p("--- URLs / hosts ---")
urls = sorted(set(s for s in cs if re.match(r"^[a-z]+://", s, re.I) or re.search(r"https?://", s)))
for s in urls:
    p(s)
p("(urls: %d)" % len(urls))

p("--- bundle-id-like / domains ---")
doms = sorted(set(s for s in cs if re.match(r"^(com|cn|org|net|io|me)\.[A-Za-z0-9_.\-]{2,60}$", s)))
for s in doms:
    p(s)
p("(domains: %d)" % len(doms))

p("--- strings with Chinese ---")
cn = sorted(set(s for s in cs if re.search(r"[\u4e00-\u9fff]", s)))
for s in cn[:250]:
    p(s)
p("(chinese strings: %d)" % len(cn))

p("--- keyword hits in all strings ---")
kw = ("yimi", "YIMI", "一米", "vip", "VIP", "会员", "watermark", "水印", "download", "下载",
      "hook", "Hook", "substrate", "Substrate", "cydia", "Cydia", "tweak", "Tweak",
      "license", "授权", "sign", "签名", "server", "api", "config", "version", "pay", "付费")
kwhits = sorted(set(s for s in cs if any(k in s for k in kw)))
for s in kwhits[:300]:
    p(s)
p("(keyword hits: %d)" % len(kwhits))

# ---------- 4. ustring ----------
blob, sec = section_bytes("ustring")
if blob:
    try:
        us = blob.decode("utf-16-le", errors="ignore")
        usx = sorted(set(x for x in re.findall(r"[\u4e00-\u9fff\w:/.@\-]{2,60}", us) if re.search(r"[\u4e00-\u9fff]", x)))
        p("\n=== __ustring: %d CJK strings ===" % len(usx))
        for s in usx[:120]:
            p(s)
    except Exception as e:
        p("ustring err %s" % e)

# ---------- 5. undefined imports of interest ----------
p("\n=== UNDEFINED IMPORTS (interesting) ---")
und = [s.name for s in b.symbols if str(s.type).endswith("UNDEFINED") and s.name]
pat = ("MSHook", "MSHookFunction", "MSHookMessageEx", "MSHookClassPair", "objc_", "_objc_",
       "dlopen", "dlsym", "sysctl", "fork", "posix_spawn", "getenv", "setuid",
       "CCCrypt", "SecItem", "SecKey", "SSL", "ssl_", "Cipher", "AES",
       "av_", "swr_", "sws_", "avcodec", "avformat")
for n in sorted(set(und)):
    if any(n.startswith(x) or x in n for x in pat):
        p(n)

p("\n=== full undefined list (count %d) ===" % len(und))
for n in sorted(set(und)):
    p(n)

txt = buf.getvalue()
open(r"E:\WorkBuddy\2026-10-17-16-34-44\macho_strings.txt", "w", encoding="utf-8").write(txt)
print(txt[:7000])
print("\n[saved macho_strings.txt, %d lines]" % txt.count("\n"))
