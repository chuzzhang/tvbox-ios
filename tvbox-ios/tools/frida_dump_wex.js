/*
 * frida_dump_wex.js —— 从 wexguard 加固壳里把真正的 dex 掉出来
 *
 * 适用：TVBox 配置里 api 是 csp_*Guard 的站点，spider 包里有
 *       assets/wexshinidie.guard + assets/wexguard_v7.so / v8.so
 *       （例：https://9280.kstore.space/aiwex.json 的那 100 个站点）
 *
 * 原理：这个壳不改 dex，是把真 dex 加密后放在 .guard 里，运行时由 so 解密，
 *       再交给 DexClassLoader / InMemoryDexClassLoader 加载。所以不去破 so，
 *       只在「即将被加载」的那一刻把字节抄下来。
 *
 * 用法（设备侧，需 root 或可运行 frida-server）：
 *   adb push frida_dump_wex.js /data/local/tmp/
 *   adb shell "su -c '/data/local/tmp/frida-server-16.x-arm64 &'"
 *   frida -U -f <TVBox包名> -l frida_dump_wex.js --no-pause
 *   然后在 App 里导入配置、点开任意一个 csp_*Guard 站点，让它触发出站点列表
 *
 * 产物落在设备 /data/local/tmp/wexdump/，拉回：
 *   adb pull /data/local/tmp/wexdump ./
 *
 * 复杂度：内存扫描是 O(可读匿名区总数)，只在 DexClassLoader 触发后跑一次，
 *         单次几百毫秒；不做全进程循环扫描，避免把设备拖死。
 */
'use strict';

var OUT_DIR = '/data/local/tmp/wexdump';
var MAX_DUMP = 32 * 1024 * 1024;   // 单个 dex 上限，防止把 oom 区当 dex 读爆
var seen = {};                      // sha1 -> 避免重复落盘

function log(msg) {
    console.log('[wex] ' + msg);
}

function ensureDir() {
    try {
        var f = new File(OUT_DIR, 'r');
        if (f.exists()) return;
    } catch (e) {}
    try {
        var d = new File(OUT_DIR, 'w');
        d.mkdirs();
        log('目录已建：' + OUT_DIR);
    } catch (e) {
        log('建目录失败（检查是否 root）：' + e);
    }
}

/* dex 头校验：magic + 版本 + file_size/header_size 合理性 */
function dexSizeAt(ptr) {
    var magic = ptr.readByteArray(8);
    if (!magic) return 0;
    var b = new Uint8Array(magic);
    if (b[0] !== 0x64 || b[1] !== 0x65 || b[2] !== 0x78 || b[3] !== 0x0a) return 0; // "dex\n"
    if (b[4] !== 0x30) return 0;
    var fileSize = ptr.add(0x20).readU32();
    var headerSize = ptr.add(0x24).readU32();
    if (headerSize !== 0x70) return 0;
    if (fileSize < 0x70 || fileSize > MAX_DUMP) return 0;
    return fileSize;
}

function save(ptr, size, tag) {
    try {
        var buf = ptr.readByteArray(size);
        if (!buf) return;
        var sha = sha1(buf);
        if (seen[sha]) return;
        seen[sha] = true;
        var name = OUT_DIR + '/' + tag + '_' + size + '_' + sha.substr(0, 8) + '.dex';
        var f = new File(name, 'wb');
        f.write(buf);
        f.flush();
        f.close();
        log('落盘 ' + name);
    } catch (e) {
        log('写文件失败：' + e);
    }
}

function sha1(buf) {
    // frida 自带 Crypto 不一定有摘要，手写够用
    var bytes = new Uint8Array(buf);
    var h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    var ml = bytes.length * 8;
    var withPad = new Uint8Array((((bytes.length + 8) >> 6) + 1) << 6);
    withPad.set(bytes);
    withPad[bytes.length] = 0x80;
    var dv = new DataView(withPad.buffer);
    dv.setUint32(withPad.length - 4, ml >>> 0, false);
    dv.setUint32(withPad.length - 8, Math.floor(ml / 4294967296), false);
    for (var i = 0; i < withPad.length; i += 64) {
        var w = new Array(80);
        for (var j = 0; j < 16; j++) w[j] = dv.getUint32(i + j * 4, false);
        for (j = 16; j < 80; j++) {
            var x = w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16];
            w[j] = ((x << 1) | (x >>> 31)) >>> 0;
        }
        var a = h[0], b2 = h[1], c = h[2], d = h[3], e = h[4];
        for (j = 0; j < 80; j++) {
            var f, k;
            if (j < 20) { f = (b2 & c) | ((~b2) & d); k = 0x5A827999; }
            else if (j < 40) { f = b2 ^ c ^ d; k = 0x6ED9EBA1; }
            else if (j < 60) { f = (b2 & c) | (b2 & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = b2 ^ c ^ d; k = 0xCA62C1D6; }
            var t = (((a << 5) | (a >>> 27)) + f + e + k + w[j]) >>> 0;
            e = d; d = c; c = ((b2 << 30) | (b2 >>> 2)) >>> 0; b2 = a; a = t;
        }
        h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b2) >>> 0; h[2] = (h[2] + c) >>> 0;
        h[3] = (h[3] + d) >>> 0; h[4] = (h[4] + e) >>> 0;
    }
    var out = '';
    for (i = 0; i < 5; i++) out += ('00000000' + h[i].toString(16)).slice(-8);
    return out;
}

/* 扫可读非文件映射区，找 dex\n035 起始 */
function scanMemory(tag) {
    var hits = 0;
    Process.enumerateRanges('r--').forEach(function (r) {
        try {
            if (r.file && r.file.path) return;       // 落在文件上的（自己 load 的 dex）跳过
            if (r.size > 64 * 1024 * 1024) return;   // 巨型映射跳过，读下来就卡死
            var p = r.base;
            var end = r.base.add(r.size - 8);
            while (p.compare(end) < 0) {
                var sz = dexSizeAt(p);
                if (sz > 0) {
                    save(p, sz, tag);
                    hits++;
                    p = p.add((sz + 7) & ~7);
                } else {
                    p = p.add(8);                        // dex 按 8 字节对齐
                }
            }
        } catch (e) {}
    });
    log('内存扫描 ' + tag + ' 命中 ' + hits + ' 个');
}

Java.perform(function () {
    ensureDir();
    log('开始挂钩');

    /* 1) DexClassLoader：路径式加载，最常见 */
    try {
        var DCL = Java.use('dalvik.system.DexClassLoader');
        DCL.$init.overload('java.lang.String', 'java.lang.String', 'java.lang.String',
                           'java.lang.ClassLoader').implementation = function (dexPath, od, lib, parent) {
            log('DexClassLoader: ' + dexPath);
            this.$init(dexPath, od, lib, parent);
            try {
                var f = new File(dexPath, 'rb');
                if (f.exists()) {
                    var size = parseInt(f.length);
                    if (size > 0 && size <= MAX_DUMP) {
                        var buf = f.readBytes(size);
                        var out = new File(OUT_DIR + '/file_' + size + '.dex', 'wb');
                        out.write(buf); out.flush(); out.close();
                        log('复制 ' + dexPath + ' → ' + OUT_DIR + '/file_' + size + '.dex');
                    }
                }
            } catch (e) { log('读 ' + dexPath + ' 失败：' + e); }
        };
    } catch (e) { log('没有 DexClassLoader：' + e); }

    /* 2) InMemoryDexClassLoader：壳最常用的那条，dex 在内存里，只能扫 */
    try {
        var IMD = Java.use('dalvik.system.InMemoryDexClassLoader');
        var hookBuf = function (tag) {
            return function (buf, parent) {
                log('InMemoryDexClassLoader 触发（' + tag + '）');
                var ret = this.$init.apply(this, arguments);
                scanMemory(tag);
                return ret;
            };
        };
        try {
            IMD.$init.overload('java.nio.ByteBuffer', 'java.lang.ClassLoader').implementation = hookBuf('imd1');
        } catch (e) {}
        try {
            IMD.$init.overload('[Ljava.nio.ByteBuffer;', 'java.lang.ClassLoader').implementation = hookBuf('imdn');
        } catch (e) {}
    } catch (e) { log('没有 InMemoryDexClassLoader（Android < 8）：' + e); }

    /* 3) 兜底：壳偶尔自己写文件再加载 */
    try {
        var FOS = Java.use('java.io.FileOutputStream');
        FOS.write.overload('[B', 'int', 'int').implementation = function (b, off, len) {
            try {
                if (len > 0x70) {
                    var magic = b[off] === 0x64 && b[off + 1] === 0x65 && b[off + 2] === 0x78;
                    if (magic) {
                        var arr = Java.array('byte', b);
                        var f = new File(OUT_DIR + '/fos_' + len + '.dex', 'wb');
                        f.write(arr); f.flush(); f.close();
                        log('FileOutputStream 抓到 dex：' + len + 'B');
                    }
                }
            } catch (e) {}
            return this.write(b, off, len);
        };
        log('FileOutputStream 已挂钩');
    } catch (e) {}

    /* 4) 加载 so 时给个提示，确认壳起没起 */
    try {
        var SL = Java.use('java.lang.System');
        SL.loadLibrary.implementation = function (name) {
            log('loadLibrary: ' + name);
            return this.loadLibrary(name);
        };
    } catch (e) {}

    log('挂钩完成，等 App 触发站点加载');
});
