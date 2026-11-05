#!/usr/bin/env python3
"""Python 3.8 pyc 只读解析器（marshal + code object 树）。

用途：分析 python 版 TVBox（Chaquopy 打包）里的 app.imy。
解开 .imy 拿到 .pyc 后，用这个列出类、函数、常量，判断框架提供什么接口。

    python tools/pyc38.py /path/to/base/spider.pyc

注意几个实际踩过的点：
  - 容器长度是 1 字节，不是 4 字节（按 4 字节读会把后续全部错位）
  - 容器类型码是 ')' / ']' / '}'，不是 '(' / '[' / '{'
  - TYPE_REF('r') 要回查 refs 表，否则 string/names 里会混进 ('REF', idx)
用 load() 拿到模块级 code object，配 walk() 遍历嵌套函数。
"""
# Python 3.8 marshal 解析器（只读，用来反解析 .pyc）
import struct

class Reader:
    def __init__(self, data):
        self.d = data; self.p = 0; self.refs = []
    def byte(self):
        b = self.d[self.p]; self.p += 1; return b
    def i32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v
    def i64(self):
        v = struct.unpack_from('<q', self.d, self.p)[0]; self.p += 8; return v
    def f64(self):
        v = struct.unpack_from('<d', self.d, self.p)[0]; self.p += 8; return v
    def s(self, n):
        v = self.d[self.p:self.p+n]; self.p += n; return v

def r_long(r): return r.i32()
def r_long64(r): return r.i64()

def r_object(r):
    code = r.byte()
    flag = code & 0x80
    t = chr(code & 0x7F)
    idx = len(r.refs)
    if flag: r.refs.append(None)
    v = _r(t, r)
    if flag: r.refs[idx] = v
    return v

def _r(t, r):
    if t == '0': return None
    if t == 'N': return None
    if t == 'F': return False
    if t == 'T': return True
    if t == 'S': return StopIteration
    if t == '.': return Ellipsis
    if t == 'i': return r_long(r)
    if t == 'I': return r_long64(r)
    if t == 'f': return struct.unpack('<f', r.s(4))[0]
    if t == 'g': return r.f64()
    if t == 'x': re_, im = r.f64(), r.f64(); return complex(re_, im)
    if t == 'y': re_, im = r.f64(), r.f64(); return complex(re_, im)
    if t == 'l':
        n = r.i32(); sign = -1 if n < 0 else 1; n = abs(n)
        v = 0
        for i in range(n):
            v |= r.byte() << (15 * i)   # 3.8 每 15 位一组
        return sign * v
    if t in ('s', 't', 'u', 'a', 'A'):
        n = r.i32(); return r.s(n).decode('utf-8', 'replace')
    if t in ('z', 'Z'):
        n = r.byte(); return r.s(n).decode('utf-8', 'replace')
    if t == 'r':
        idx = r.i32()
        return r.refs[idx] if 0 <= idx < len(r.refs) else None
    if t in (')', '('):
        n = r.byte(); return tuple(r_object(r) for _ in range(n))
    if t in (']', '['):
        n = r.byte(); return [r_object(r) for _ in range(n)]
    if t in ('}', '{'):
        out = {}
        while True:
            if r.p < len(r.d) and r.d[r.p] == 0x30:   # TYPE_NULL 结尾
                r.p += 1
                break
            k = r_object(r)
            v = r_object(r)
            out[k] = v
        return out
    if t == '<':
        n = r.i32(); return {r_object(r) for _ in range(n)}
    if t == '>':
        n = r.i32(); return frozenset(r_object(r) for _ in range(n))
    if t == 'c':
        c = {}
        c['argcount'] = r_long(r); c['posonlyargcount'] = r_long(r)
        c['kwonlyargcount'] = r_long(r); c['nlocals'] = r_long(r)
        c['stacksize'] = r_long(r); c['flags'] = r_long(r)
        c['code'] = r_object(r); c['consts'] = r_object(r)
        c['names'] = r_object(r); c['varnames'] = r_object(r)
        c['freevars'] = r_object(r); c['cellvars'] = r_object(r)
        c['filename'] = r_object(r); c['name'] = r_object(r)
        c['firstlineno'] = r_long(r); c['lnotab'] = r_object(r)
        return c
    raise ValueError('unknown type %r at %d' % (t, r.p))

def load(path):
    d = open(path, 'rb').read()
    r = Reader(d)
    magic = r.s(4); r.s(4); r.s(4); r.s(4)   # magic, flags, mtime, size
    return r_object(r)

def walk(code, depth=0, out=None):
    if out is None: out = []
    out.append((depth, code))
    for c in code.get('consts', ()):
        if isinstance(c, dict) and 'code' in c:
            walk(c, depth+1, out)
    return out
