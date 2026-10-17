# -*- coding: utf-8 -*-
"""Mach-O static structural analysis v2 - libCoreMediaAssist-v4.7(1).dylib"""
import lief, sys, io
from collections import Counter

buf = io.StringIO()
def p(*a):
    s = " ".join(str(x) for x in a)
    buf.write(s + "\n")

TARGET = r"E:\WorkBuddy\2026-10-17-16-34-44\target.dylib"
b = lief.parse(TARGET)
h = b.header

def cn(cmd):
    return str(cmd.command).split(".")[-1]

p("=== HEADER ===")
p("magic: %s | cputype: %s | filetype: %s" % (h.magic, h.cpu_type, h.file_type))
p("ncmds: %d sizeofcmds: %d flags: %s" % (h.nb_cmds, h.sizeof_cmds, [str(x).split('.')[-1] for x in h.flags_list]))

p("\n=== UUID / BUILD VERSION / ID_DYLIB ===")
p("uuid: %s" % str(b.uuid).upper())
for cmd in b.commands:
    n = cn(cmd)
    if n in ("BUILD_VERSION", "VERSION_MIN_MACOSX", "VERSION_MIN_IPHONEOS", "VERSION_MIN_TVOS", "VERSION_MIN_WATCHOS"):
        p("%s: platform=%s minos=%s sdk=%s" % (n, getattr(cmd, "platform", None), getattr(cmd, "minos", None), getattr(cmd, "sdk", None)))
    if n == "ID_DYLIB":
        p("LC_ID_DYLIB install_name: %s (current=%s compat=%s)" % (cmd.name, cmd.current_version, cmd.compatibility_version))

p("\n=== LOAD COMMAND COUNTS ===")
c = Counter(cn(cmd) for cmd in b.commands)
for k, v in sorted(c.items()):
    p("%-28s %d" % (k, v))

p("\n=== DEPENDENT LIBRARIES ===")
for cmd in b.commands:
    if cn(cmd) in ("LOAD_DYLIB", "LOAD_WEAK_DYLIB", "REEXPORT_DYLIB", "LAZY_LOAD_DYLIB", "LOAD_UPWARD_DYLIB"):
        p("%-18s %-60s current=%s compat=%s" % (cn(cmd), cmd.name, cmd.current_version, cmd.compatibility_version))

p("\n=== RPATHS ===")
for cmd in b.commands:
    if cn(cmd) == "RPATH":
        p(cmd.path)

p("\n=== ENCRYPTION CHECK ===")
found = False
for cmd in b.commands:
    if cn(cmd) in ("ENCRYPTION_INFO", "ENCRYPTION_INFO_64"):
        found = True
        p("%s: crypt_id=%s offset=%s size=%s" % (cn(cmd), cmd.crypt_id, cmd.crypt_offset, cmd.crypt_size))
if not found:
    p("no LC_ENCRYPTION_INFO -> binary is NOT FairPlay-encrypted (already decrypted)")

p("\n=== SEGMENTS / SECTIONS ===")
for seg in b.segments:
    p("SEG %-12s vm=0x%x vsize=0x%x off=0x%x fsize=0x%x" % (seg.name, seg.virtual_address, seg.virtual_size, seg.file_offset, seg.file_size))
    for s in seg.sections:
        p("   %-20s vm=0x%010x vsize=0x%07x off=0x%07x" % (s.name, s.virtual_address, s.size, s.offset))

p("\n=== SYMBOLS: %d total ===" % len(b.symbols))
cats = Counter(str(s.category).split(".")[-1] for s in b.symbols)
for k, v in cats.most_common():
    p("category %-20s %d" % (k, v))
types = Counter(str(s.type).split(".")[-1] for s in b.symbols)
for k, v in types.most_common():
    p("type %-22s %d" % (k, v))

names = [s.name for s in b.symbols if s.name]
uniq = sorted(set(names))
p("unique names: %d" % len(uniq))

p("\n--- EXPORTED (has_export_info) names, first 250 ---")
exp = [s.name for s in b.symbols if s.has_export_info]
p("exported count: %d" % len(exp))
for n in sorted(set(exp))[:250]:
    p(n)

p("\n--- symbol namespace histogram ---")
pref = Counter()
for n in uniq:
    if "_OBJC_CLASS_$_" in n: pref["OBJC class def"] += 1
    elif "_OBJC_METACLASS_$_" in n: pref["OBJC metaclass def"] += 1
    elif "_OBJC_IVAR_$_" in n: pref["OBJC ivar def"] += 1
    elif n.startswith("_$s") or n.startswith("$s"): pref["Swift mangled"] += 1
    elif n.startswith("__ZN") or n.startswith("_ZN"): pref["C++ mangled"] += 1
    elif n.startswith("__Z") or n.startswith("_Z"): pref["C mangled"] += 1
    elif "__objc" in n or n.startswith("_objc"): pref["objc runtime meta"] += 1
    elif "_OBJC_EHTYPE" in n or "__OBJC" in n: pref["objc eh"] += 1
    else: pref["other/plain C"] += 1
for k, v in pref.most_common():
    p("%-18s %d" % (k, v))

p("\n--- ObjC class names defined ---")
cls = sorted(set(n.split("_OBJC_CLASS_$_")[-1] for n in uniq if "_OBJC_CLASS_$_" in n))
for n in cls: p(n)
p("objc classes: %d" % len(cls))

p("\n--- Swift mangled samples (first 80) ---")
sw = [n for n in uniq if n.startswith("_$s") or n.startswith("$s")]
for n in sw[:80]: p(n)
p("swift symbols: %d" % len(sw))

p("\n--- plain C / misc exported names (sample) ---")
others = sorted(set(n for n in exp if not n.startswith("_$s") and "_OBJC" not in n))
for n in others[:150]: p(n)

p("\n=== FUNCTIONS (LC_FUNCTION_STARTS): %d ===" % len(b.functions))
sizes = sorted((f.size for f in b.functions), reverse=True)
p("top sizes: %s" % [hex(x) for x in sizes[:12]])
big = sorted(b.functions, key=lambda f: f.size, reverse=True)[:5]
for f in big:
    p("big fn @0x%x size=0x%x" % (f.address, f.size))

p("\n=== OBJC METADATA (lief) ===")
try:
    oc = list(b.objc_classes)
    p("lief objc classes: %d" % len(oc))
    for c in oc[:60]:
        try:
            ms = list(c.methods)
            p("class %-40s methods=%d" % (c.name, len(ms)))
        except Exception:
            p("class %s (methods n/a)" % c.name)
except Exception as e:
    p("objc metadata unavailable: %s" % e)

p("\n=== CODE SIGNATURE ===")
try:
    cs = b.code_signature
    p("code_signature object: %s" % (cs is not None))
except Exception as e:
    p("cs n/a: %s" % e)

p("\n=== INSTRUMENTATION / OTHER CMDS ===")
for cmd in b.commands:
    n = cn(cmd)
    if n not in ("SEGMENT_64", "LOAD_DYLIB", "LOAD_WEAK_DYLIB", "RPATH", "ID_DYLIB", "BUILD_VERSION",
                 "SYMTAB", "DYSYMTAB", "DYLD_INFO", "DYLD_EXPORTS_TRIE", "DYLD_CHAINED_FIXUPS",
                 "FUNCTION_STARTS", "DATA_IN_CODE", "CODE_SIGNATURE", "LINKEDIT_DATA", "DYLIB_CODE_SIGN_DRS",
                 "SUB_CLIENT", "SOURCE_VERSION", "BUILD_TOOL_VERSION"):
        p("notable cmd: %s -> %s" % (n, cmd))

txt = buf.getvalue()
open(r"E:\WorkBuddy\2026-10-17-16-34-44\macho_structure.txt", "w", encoding="utf-8").write(txt)
print(txt[:6000])
print("\n[full report saved: macho_structure.txt, %d lines]" % txt.count("\n"))
