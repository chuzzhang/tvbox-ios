#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dex_scan.py —— 从 TVBox 的 spider jar 里抽站点实现用到的字符串

用途：`api: csp_XXX` 的站点，实现全在顶层 spider 的 classes.dex 里，iOS 跑不了。
要用起来就得把它改写成 js（或 drpy 规则），改写第一步是搞清楚**这个类请求了哪些地址**。
本工具不反编译、不建 CFG：直接解析 dex 的 string_ids / class_defs / code_item，
把每个方法里 const-string 引用的字符串按类归好，按"像不像接口地址"排序输出。

用法：
    python tools/dex_scan.py pg.jar                  # 全部站点类
    python tools/dex_scan.py pg.jar --site csp_GM    # 只看某几个
    python tools/dex_scan.py pg.jar --json out.json  # 机器可读

dex 格式要点（本工具实际用到的）：
    header 0x38 起 string_ids_size/off，type_ids，class_defs
    string_data_item = uleb128(utf16_len) + MUTF-8
    class_def  32 字节，含 class_idx / class_data_off
    class_data = uleb128 计数的字段与方法列表
    code_item  = 16 字节头 + insns[]，const-string 是 0x1a（21c）/ 0x1b（31c jumbo）

复杂度：O(方法数 × 指令数)，4.6 MB 的 jar 上大约 2-3 秒。
"""
import argparse
import io
import json
import os
import re
import struct
import sys
import zipfile

# 判断"这条字符串值不值得看"：接口地址、域名、参数名
HINT = re.compile(
    r"(https?://|/api|\.php|\.json|\.html|\.m3u8|\.com|\.net|\.vip|\.cc|\.me|\.top|\.xyz"
    r"|ac=|wd=|pg=|ids=|token|sign|key=|hm=|device|ua=|referer)", re.I)
BAD = re.compile(r"^[A-Za-z0-9_$/]{0,3}$")


def uleb128(buf, off):
    result = shift = 0
    while True:
        b = buf[off]
        off += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, off
        shift += 7


class Dex:
    def __init__(self, data):
        if data[:4] != b"dex\n":
            raise ValueError("不是 dex（魔数不符）")
        self.buf = data
        # 头部每项是 (size, off) 成对排列，偏移分别错开 8 字节：
        # 0x38 string_ids、0x40 type_ids、0x48 proto_ids、0x50 field_ids、
        # 0x58 method_ids、0x60 class_defs。整段一次性 unpack 会把它们挪位。
        def pair(off):
            return struct.unpack_from("<II", data, off)

        self.string_ids_size, self.string_ids_off = pair(0x38)
        self.type_ids_size, self.type_ids_off = pair(0x40)
        self.proto_ids_size, self.proto_ids_off = pair(0x48)
        self.field_ids_size, self.field_ids_off = pair(0x50)
        self.method_ids_size, self.method_ids_off = pair(0x58)
        self.class_defs_size, self.class_defs_off = pair(0x60)
        self._strings = None
        self._types = None

    # ---- 字符串表
    def strings(self):
        if self._strings is not None:
            return self._strings
        out = []
        for i in range(self.string_ids_size):
            off = struct.unpack_from("<I", self.buf, self.string_ids_off + 4 * i)[0]
            _, p = uleb128(self.buf, off)
            end = self.buf.find(b"\x00", p)
            raw = self.buf[p:end]
            # MUTF-8 与 UTF-8 在 BMP 内一致，替换非法字节即可
            out.append(raw.decode("utf-8", "replace"))
        self._strings = out
        return out

    def types(self):
        if self._types is not None:
            return self._types
        ss = self.strings()
        out = [ss[struct.unpack_from("<I", self.buf, self.type_ids_off + 4 * i)[0]]
               for i in range(self.type_ids_size)]
        self._types = out
        return out

    # ---- class_def 遍历
    def classes(self):
        ss, ts = self.strings(), self.types()
        out = []
        for i in range(self.class_defs_size):
            base = self.class_defs_off + 32 * i
            class_idx, _flags = struct.unpack_from("<II", self.buf, base)
            class_data_off = struct.unpack_from("<I", self.buf, base + 24)[0]
            name = ts[class_idx] if class_idx < len(ts) else ""
            out.append((name.strip("L;").replace("/", "."), class_data_off))
        return out

    def method_strings(self, class_data_off):
        """把一个类的所有方法里 const-string 引用到的字符串捞出来"""
        if class_data_off == 0 or class_data_off >= len(self.buf):
            return []
        ss = self.strings()
        buf = self.buf
        p = class_data_off
        sf, p = uleb128(buf, p)
        inf, p = uleb128(buf, p)
        dm, p = uleb128(buf, p)
        vm, p = uleb128(buf, p)
        for _ in range(sf + inf):          # 跳过字段
            _, p = uleb128(buf, p)
            _, p = uleb128(buf, p)
        found = []
        for count in (dm, vm):             # direct + virtual 方法
            midx = 0
            for _ in range(count):
                diff, p = uleb128(buf, p)
                midx += diff
                _, p = uleb128(buf, p)     # access_flags
                code_off, p = uleb128(buf, p)
                if code_off:
                    found.extend(self._code_strings(code_off, ss))
        # 去重保序
        seen, uniq = set(), []
        for s in found:
            if s and s not in seen:
                seen.add(s)
                uniq.append(s)
        return uniq

    def _code_strings(self, code_off, ss):
        insns_size = struct.unpack_from("<I", self.buf, code_off + 12)[0]
        base = code_off + 16
        out = []
        for i in range(insns_size):
            w = struct.unpack_from("<H", self.buf, base + 2 * i)[0]
            op = w & 0xFF
            if op == 0x1A:                             # const-string vAA, string@BBBB
                if i + 1 < insns_size:
                    idx = struct.unpack_from("<H", self.buf, base + 2 * (i + 1))[0]
                    if idx < len(ss):
                        out.append(ss[idx])
                i += 1
            elif op == 0x1B:                           # const-string/jumbo
                if i + 2 < insns_size:
                    idx = struct.unpack_from("<I", self.buf, base + 2 * (i + 1))[0]
                    if idx < len(ss):
                        out.append(ss[idx])
                i += 2
        return out


def load_dex_from(path):
    """jar/zip 里取 classes*.dex；本身是 dex 就直接读"""
    raw = open(path, "rb").read()
    if raw[:4] == b"dex\n":
        return [(os.path.basename(path), raw)]
    if raw[:2] != b"PK":
        raise SystemExit(f"{path} 既不是 jar 也不是 dex")
    z = zipfile.ZipFile(io.BytesIO(raw))
    return [(n, z.read(n)) for n in z.namelist() if n.endswith(".dex")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jar")
    ap.add_argument("--site", action="append", default=[],
                    help="只看这些类名/关键字（可多次传）：--site csp_GM --site Sukebei")
    ap.add_argument("--json", help="结果写到这个文件")
    ap.add_argument("--min", type=int, default=1, help="每个类至少保留几条有用字符串")
    ap.add_argument("--all", action="store_true",
                    help="不做地址过滤，原样列出该类的全部字符串（混淆包排查用）")
    args = ap.parse_args()

    result = {}
    for dex_name, data in load_dex_from(args.jar):
        try:
            dex = Dex(data)
        except ValueError as e:
            print(f"! {dex_name}: {e}")
            continue
        for cls, off in dex.classes():
            if not cls:
                continue
            if args.site and not any(k.lower() in cls.lower() for k in args.site):
                continue
            strs = dex.method_strings(off)
            hits = strs if args.all else [s for s in strs if HINT.search(s) and not BAD.match(s)]
            if len(hits) < args.min:
                continue
            result[cls] = hits

    if args.json:
        json.dump(result, open(args.json, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        print(f"写入 {args.json}（{len(result)} 个类）")
        return

    print(f"命中 {len(result)} 个类\n")
    if not result and not args.all:
        print("没有类命中地址特征。两种可能：")
        print("  1) 这个 jar 的字符串被混淆/加密（域名在运行期拼出来），扫字符串没用")
        print("     这类包只能 jadx 反编译看调用链，或真机 frida hook 网络层抓真实请求")
        print("  2) 类名对不上，用 --all 看一个类的原始字符串再判断")
        print()
    for cls in sorted(result):
        print(f"== {cls}")
        for s in result[cls][:24]:
            print("   ", s if len(s) <= 120 else s[:117] + "…")
        if len(result[cls]) > 24:
            print(f"    …共 {len(result[cls])} 条")
        print()


if __name__ == "__main__":
    main()
