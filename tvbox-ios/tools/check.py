#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
工程静态校验（Windows / macOS / Linux 通用，不依赖 Xcode）

做四件事：
1. Swift 词法扫描：剥掉注释与字符串后检查 {} () [] 与 #if/#endif 配对
2. Info.plist XML 合法性
3. project.yml 里引用的路径是否都存在
4. 顶层类型声明是否有重名 / 是否有残留占位符

用法：python tools/check.py
"""
import os
import re
import sys
import glob
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ERRORS = []
WARNS = []


def err(msg):
    ERRORS.append(msg)


def warn(msg):
    WARNS.append(msg)


# ---------------------------------------------------------------- Swift 词法
def strip_swift(src):
    """把注释、字符串、原始字符串全部替换成空格（保留换行），返回纯代码文本。"""
    out = []
    i, n = 0, len(src)

    def blank(ch):
        return '\n' if ch == '\n' else ' '

    while i < n:
        c = src[i]

        # 行注释
        if src.startswith('//', i):
            while i < n and src[i] != '\n':
                out.append(blank(src[i]))
                i += 1
            continue

        # 块注释（Swift 支持嵌套）
        if src.startswith('/*', i):
            depth = 0
            while i < n:
                if src.startswith('/*', i):
                    depth += 1
                    out.append('  ')
                    i += 2
                elif src.startswith('*/', i):
                    depth -= 1
                    out.append('  ')
                    i += 2
                    if depth == 0:
                        break
                else:
                    out.append(blank(src[i]))
                    i += 1
            continue

        # 原始字符串 #"..."# / #"""..."""#
        m = re.match(r'(#+)("""|")', src[i:])
        if m:
            hashes, quote = m.group(1), m.group(2)
            terminator = quote + hashes
            j = i + len(m.group(0))
            while j < n and not src.startswith(terminator, j):
                out.append(blank(src[j]))
                j += 1
            for _ in range(len(terminator)):
                out.append(' ')
            i = j + len(terminator)
            continue

        # 多行字符串
        if src.startswith('"""', i):
            j = i + 3
            while j < n and not src.startswith('"""', j):
                out.append(blank(src[j]))
                j += 1
            out.append('   ')
            i = j + 3
            continue

        # 普通字符串（含 \( ) 插值）
        if c == '"':
            out.append(' ')
            i += 1
            while i < n:
                ch = src[i]
                if ch == '\\':
                    # 转义：\( 进入插值，按括号配对跳过
                    if i + 1 < n and src[i + 1] == '(':
                        out.append('  ')
                        i += 2
                        depth = 1
                        while i < n and depth > 0:
                            if src[i] == '(':
                                depth += 1
                            elif src[i] == ')':
                                depth -= 1
                            out.append(blank(src[i]))
                            i += 1
                        continue
                    out.append('  ')
                    i += 2
                    continue
                if ch == '"':
                    out.append(' ')
                    i += 1
                    break
                if ch == '\n':          # 单行字符串未闭合
                    break
                out.append(' ')
                i += 1
            continue

        out.append(c)
        i += 1

    return ''.join(out)


def check_balance(path, code):
    pairs = {'}': '{', ')': '(', ']': '['}
    stack = []
    line = 1
    for idx, ch in enumerate(code):
        if ch == '\n':
            line += 1
        elif ch in '{([':
            stack.append((ch, line))
        elif ch in '})]':
            if not stack:
                err(f'{path}:{line} 多余的 "{ch}"')
                return
            open_ch, open_line = stack.pop()
            if pairs[ch] != open_ch:
                err(f'{path}:{line} "{ch}" 与第 {open_line} 行的 "{open_ch}" 不匹配')
                return
    for ch, ln in stack:
        err(f'{path}:{ln} "{ch}" 未闭合')


def check_directives(path, lines):
    depth = 0
    for i, raw in enumerate(lines, 1):
        s = raw.strip()
        if re.match(r'^#if\b', s):
            depth += 1
        elif re.match(r'^#endif\b', s):
            depth -= 1
            if depth < 0:
                err(f'{path}:{i} 多余的 #endif')
                depth = 0
    if depth != 0:
        err(f'{path} 有 {depth} 个 #if 没有 #endif')


TYPE_RE = re.compile(
    r'^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*'
    r'(?:struct|class|enum|protocol|actor)\s+([A-Z][A-Za-z0-9_]*)', re.M)

# 这几个 helper 返回的是非可选 String（取不到给空串）。
# 写成 `if let x = URLKit.origin(...)` 编不过：conditional binding 要求 Optional。
# 编译器只会报 "initializer for conditional binding must have Optional type"，
# 一行一个，改一轮发现一个，很费时间 —— 这里提前拦掉。
NON_OPTIONAL_HELPERS = (
    'URLKit.origin',
    'URLKit.base',
    'URLKit.resolve',
    'URLKit.looksLikeURL',
    'URLKit.relativize',
)

BIND_RE = re.compile(r'\b(?:if|guard)\s+let\s+[A-Za-z_]\w*\s*=\s*([^,{\n]*)')


def check_bindings(path, code):
    """if/guard let 绑定的右侧如果是非可选返回值的 helper，直接报错。"""
    for line_no, line in enumerate(code.splitlines(), 1):
        for m in BIND_RE.finditer(line):
            expr = m.group(1)
            if 'try?' in expr or 'as?' in expr:
                continue
            for helper in NON_OPTIONAL_HELPERS:
                if expr.strip().startswith(helper + '('):
                    err(f'{path}:{line_no} `{helper}()` 返回 String 不是 Optional，'
                        f'不能用 if/guard let 绑定（改成 let x = ...; if !x.isEmpty）')


def collect_types(swift_files):
    decl = {}
    for p in swift_files:
        src = open(p, encoding='utf-8').read()
        for m in TYPE_RE.finditer(src):
            name = m.group(1)
            decl.setdefault(name, []).append(os.path.basename(p))
    for name, files in decl.items():
        if len(files) > 1:
            err(f'类型重名：{name} 同时声明在 {", ".join(files)}')
    return decl


PLACEHOLDERS = ['TODO', 'FIXME', '这里省略', '其余同理', '按上面的方式处理', 'your_api_key']


def main():
    swift_files = sorted(glob.glob(os.path.join(ROOT, 'Sources', '*.swift')))
    if not swift_files:
        err('Sources/ 下没有 .swift 文件')
        report()
        return

    total_lines = 0
    for p in swift_files:
        raw = open(p, encoding='utf-8').read()
        rel = os.path.relpath(p, ROOT).replace('\\', '/')
        total_lines += raw.count('\n') + 1

        for kw in PLACEHOLDERS:
            if kw in raw:
                err(f'{rel} 残留占位符：{kw}')

        code = strip_swift(raw)
        check_balance(rel, code)
        check_directives(rel, raw.splitlines())
        check_bindings(rel, code)

        # 未闭合的字符串会表现为引号计数为奇数（排除 """ 与 #"）
        plain = re.sub(r'"""[\s\S]*?"""', '', raw)
        plain = re.sub(r'#"[\s\S]*?"#', '', plain)
        if len(re.findall(r'(?<!\\)"', plain)) % 2 != 0:
            warn(f'{rel} 引号数量为奇数，可能有未闭合字符串')

    collect_types(swift_files)

    # Info.plist
    plist = os.path.join(ROOT, 'Info.plist')
    if not os.path.exists(plist):
        err('缺少 Info.plist')
    else:
        try:
            tree = ET.parse(plist)
            keys = [e.text for e in tree.getroot().iter('key')]
            for need in ('CFBundleIdentifier', 'CFBundleExecutable', 'MinimumOSVersion'):
                if need == 'MinimumOSVersion':
                    continue  # 由 xcodegen 写入
                if need not in keys:
                    err(f'Info.plist 缺少 {need}')
        except ET.ParseError as e:
            err(f'Info.plist XML 解析失败：{e}')

    # project.yml 引用路径
    proj = os.path.join(ROOT, 'project.yml')
    if not os.path.exists(proj):
        err('缺少 project.yml')
    else:
        text = open(proj, encoding='utf-8').read()
        for m in re.finditer(r'-\s*path:\s*([A-Za-z0-9_./]+)', text):
            rel = m.group(1).rstrip('/')
            if not os.path.exists(os.path.join(ROOT, rel)):
                err(f'project.yml 引用了不存在的路径：{rel}')
        if 'packages:' in text:
            for m in re.finditer(r'url:\s*(\S+)', text):
                if not m.group(1).startswith('https://'):
                    err(f'依赖地址异常：{m.group(1)}')

    # build.sh 可执行位（类 Unix 下才有意义）
    bsh = os.path.join(ROOT, 'build.sh')
    if os.path.exists(bsh) and os.name != 'nt':
        if not os.access(bsh, os.X_OK):
            warn('build.sh 没有执行权限：chmod +x build.sh')

    print(f'扫描 {len(swift_files)} 个 Swift 文件，{total_lines} 行')
    report()


def report():
    for w in WARNS:
        print(f'  WARN  {w}')
    if ERRORS:
        print()
        for e in ERRORS:
            print(f'  FAIL  {e}')
        print(f'\n{len(ERRORS)} 个问题')
        sys.exit(1)
    print(f'  OK    结构检查通过（{len(WARNS)} 个提示）')


if __name__ == '__main__':
    main()
