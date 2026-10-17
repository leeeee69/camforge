# -*- coding: utf-8 -*-
"""CFString extraction + code signature entitlements + targeted selector scan"""
import lief, re, struct, io

buf = io.StringIO()
def p(*a):
    s = " ".join(str(x) for x in a)
    buf.write(s + "\n")

TARGET = r"E:\WorkBuddy\2026-10-17-16-34-44\target.dylib"
raw = open(TARGET, "rb").read()
b = lief.parse(TARGET)

# vm -> file offset map
segs = [(s.virtual_address, s.virtual_size, s.file_offset, s.file_size) for s in b.segments]
def vm2off(vm):
    for va, vs, off, fs in segs:
        if va <= vm < va + vs:
            return off + (vm - va)
    return None

# ---------- CFStrings ----------
cf_sec = None
for seg in b.segments:
    for s in seg.sections:
        if s.name == "__cfstring":
            cf_sec = (s.offset, s.size)
p("=== __cfstring records ===")
if cf_sec:
    off, size = cf_sec
    n = size // 32
    found = []
    for i in range(n):
        rec = raw[off + i * 32: off + (i + 1) * 32]
        if len(rec) < 32:
            break
        # 64-bit CFString: isa(8) info(8) length(8) dataptr(8)
        info = struct.unpack("<Q", rec[8:16])[0]
        length = struct.unpack("<Q", rec[16:24])[0]
        dataptr = struct.unpack("<Q", rec[24:32])[0]
        if dataptr == 0 or length > 500 or length == 0:
            continue
        fo = vm2off(dataptr)
        if fo is None:
            continue
        blob = raw[fo:fo + length]
        try:
            if info & 0x08:  # UTF-16
                txt = blob.decode("utf-16-le", errors="replace")
            else:
                txt = blob.decode("latin-1", errors="replace")
            found.append(txt)
        except Exception:
            pass
    p("decoded CFStrings: %d" % len(found))
    for t in sorted(set(found)):
        if len(t) >= 2:
            p(repr(t))
else:
    p("no __cfstring section")

# ---------- code signature entitlements ----------
p("\n=== CODE SIGNATURE / ENTITLEMENTS ===")
cs_cmd = None
for cmd in b.commands:
    if str(cmd.command).split(".")[-1] == "CODE_SIGNATURE":
        cs_cmd = cmd
if cs_cmd:
    base = cs_cmd.data_offset
    p("codesign blob at file offset 0x%x size 0x%x" % (base, cs_cmd.data_size))
    sb = raw[base:base + cs_cmd.data_size]
    magic, length, count = struct.unpack(">III", sb[:12])
    p("superblob magic=0x%x len=%d blobs=%d" % (magic, length, count))
    # walk index
    idx = 12
    blobs = []
    for i in range(count):
        typ, off = struct.unpack(">II", sb[idx:idx + 8])
        idx += 8
        blobs.append((typ, off))
        p("  blob[%d] type=0x%08x offset=%d" % (i, typ, off))
    # 0xfade7172 = entitlements
    for typ, off in blobs:
        if typ == 0xfade7172:
            emagic, elen = struct.unpack(">II", sb[off:off + 8])
            p("entitlements blob len=%d" % elen)
            xml = sb[off + 8: off + elen]
            try:
                t = xml.decode("utf-8", errors="replace")
                p(t[:4000])
            except Exception as e:
                p("decode err %s" % e)
else:
    p("no LC_CODE_SIGNATURE")

# ---------- targeted selector scan ----------
p("\n=== SELECTOR THEMES ===")
blob = None
for seg in b.segments:
    for s in seg.sections:
        if s.name == "__objc_methname":
            blob = raw[s.offset:s.offset + s.size]
sels, cur = [], bytearray()
for ch in blob:
    if ch == 0:
        if len(cur) >= 3:
            sels.append(cur.decode("latin-1"))
        cur = bytearray()
    else:
        cur.append(ch)
sels = sorted(set(sels))
themes = {
  "license/auth": ("icense", "uth", "ctivation", "卡密", "ctivate", "ign", "erify", "evice", "achine", "rust", "xpir"),
  "watermark/invisible": ("atermark", "nvisible", "人眼", "race", "eak"),
  "usb": ("USB", "usb", "Puller", "peer", "companion"),
  "rtsp/network": ("rtsp", "RTSP", "hls", "HLS", "network", "Network", "stream", "Stream", "pull", "Pull"),
  "hook/antidebug": ("hook", "Hook", "swizzle", "Swizzle", "debug", "Debug", "tamper", "Tamper", "detect", "Detect", "guard", "Guard", "ban", "Ban"),
  "voice clone": ("clone", "Clone", "voice", "Voice", "tts", "TTS"),
  "server/api": ("server", "Server", "api", "API", "php", "branding", "Branding", "announce", "Announce"),
  "aweme/douyin": ("aweme", "Aweme", "douyin", "Douyin", "tiktok", "TikTok"),
}
for name, kws in themes.items():
    hits = [s for s in sels if any(k in s for k in kws)]
    p("--- %s (%d) ---" % (name, len(hits)))
    for s in hits[:60]:
        p(s)

txt = buf.getvalue()
open(r"E:\WorkBuddy\2026-10-17-16-34-44\macho_cfstring_sig.txt", "w", encoding="utf-8").write(txt)
print(txt[:8000])
print("\n[saved macho_cfstring_sig.txt, %d lines]" % txt.count("\n"))
