package wen

import std.collection.*
import std.overflow.*

/*
 * 自写的 SHA-256 与 HMAC-SHA256(零依赖)。
 *
 * 替换缝(REPLACEMENT SEAM)
 * --------------------------
 * 仓颉的 `std.crypto.digest` 只提供 `Digest` 接口,具体算法(SHA256/HMAC 等)在
 * 扩展库 `stdx.crypto.digest` 里;当前环境未安装 stdx,故这里按标准自行实现一份,
 * 并用 NIST/RFC 已知向量验证正确性。
 *
 * 框架其余部分只通过下面这个稳定入口使用签名能力:
 *   - hmacSha256Hex(key, msg): String   // 返回十六进制 HMAC
 * 日后若装好 stdx,只需重写本文件、保持该签名不变(内部改为委托 stdx.crypto.digest),
 * 调用点(签名 Cookie / session)无需改动。
 *
 * 注意:UInt32 的加法在仓颉默认是检查溢出会抛异常的,SHA-256 需要的是"环绕加法",
 * 因此所有模 2^32 的加法都改用 std.overflow 的 wrappingAdd;移位则是截断语义,
 * 可直接用于循环右移。
 */

// SHA-256 的 64 个轮常量。
let SHA256_K: Array<UInt32> = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2
]

// 32 位循环右移(移位为截断语义,故 (x>>n) | (x<<(32-n)) 正好得到循环右移)。
func rotr(x: UInt32, n: UInt32): UInt32 {
    return (x >> n) | (x << (UInt32(32) - n))
}

// 把一个 UInt32 以大端序写入 out 的 idx 处(4 字节)。
func writeBE32(out: Array<UInt8>, idx: Int64, v: UInt32): Unit {
    out[idx] = UInt8((v >> 24) & UInt32(0xFF))
    out[idx + 1] = UInt8((v >> 16) & UInt32(0xFF))
    out[idx + 2] = UInt8((v >> 8) & UInt32(0xFF))
    out[idx + 3] = UInt8(v & UInt32(0xFF))
}

// 计算 data 的 SHA-256 摘要,返回 32 字节。
func sha256(data: Array<UInt8>): Array<UInt8> {
    var h0: UInt32 = 0x6a09e667
    var h1: UInt32 = 0xbb67ae85
    var h2: UInt32 = 0x3c6ef372
    var h3: UInt32 = 0xa54ff53a
    var h4: UInt32 = 0x510e527f
    var h5: UInt32 = 0x9b05688c
    var h6: UInt32 = 0x1f83d9ab
    var h7: UInt32 = 0x5be0cd19

    // 填充:追加 0x80,补 0 直到长度 ≡ 56 (mod 64),再附上 64 位大端比特长度。
    let bitLen = UInt64(data.size) * UInt64(8)
    let msg = ArrayList<UInt8>()
    for (b in data) {
        msg.add(b)
    }
    msg.add(UInt8(0x80))
    while (msg.size % 64 != 56) {
        msg.add(UInt8(0))
    }
    var i = 7
    while (i >= 0) {
        msg.add(UInt8((bitLen >> UInt64(i * 8)) & UInt64(0xFF)))
        i -= 1
    }

    let allOnes: UInt32 = 0xFFFFFFFF
    var off = 0
    while (off < msg.size) {
        let w = Array<UInt32>(64, repeat: 0)
        var t = 0
        while (t < 16) {
            let j = off + t * 4
            w[t] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16) | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            t += 1
        }
        t = 16
        while (t < 64) {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16].wrappingAdd(s0).wrappingAdd(w[t - 7]).wrappingAdd(s1)
            t += 1
        }

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var hh = h7
        t = 0
        while (t < 64) {
            let bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ ((e ^ allOnes) & g)
            let temp1 = hh.wrappingAdd(bigS1).wrappingAdd(ch).wrappingAdd(SHA256_K[t]).wrappingAdd(w[t])
            let bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = bigS0.wrappingAdd(maj)
            hh = g
            g = f
            f = e
            e = d.wrappingAdd(temp1)
            d = c
            c = b
            b = a
            a = temp1.wrappingAdd(temp2)
            t += 1
        }

        h0 = h0.wrappingAdd(a)
        h1 = h1.wrappingAdd(b)
        h2 = h2.wrappingAdd(c)
        h3 = h3.wrappingAdd(d)
        h4 = h4.wrappingAdd(e)
        h5 = h5.wrappingAdd(f)
        h6 = h6.wrappingAdd(g)
        h7 = h7.wrappingAdd(hh)
        off += 64
    }

    let out = Array<UInt8>(32, repeat: 0)
    writeBE32(out, 0, h0)
    writeBE32(out, 4, h1)
    writeBE32(out, 8, h2)
    writeBE32(out, 12, h3)
    writeBE32(out, 16, h4)
    writeBE32(out, 20, h5)
    writeBE32(out, 24, h6)
    writeBE32(out, 28, h7)
    return out
}

// HMAC-SHA256(RFC 2104):H((K ^ opad) || H((K ^ ipad) || msg))。
func hmacSha256(key: Array<UInt8>, msg: Array<UInt8>): Array<UInt8> {
    let blockSize = 64
    // 超过分组长度的密钥先做一次哈希;再右补 0 到分组长度。
    var k = key
    if (k.size > blockSize) {
        k = sha256(k)
    }
    let k0 = Array<UInt8>(blockSize, repeat: 0)
    var i = 0
    while (i < k.size && i < blockSize) {
        k0[i] = k[i]
        i += 1
    }

    let inner = ArrayList<UInt8>()
    let outer = ArrayList<UInt8>()
    i = 0
    while (i < blockSize) {
        inner.add(k0[i] ^ UInt8(0x36))
        outer.add(k0[i] ^ UInt8(0x5c))
        i += 1
    }
    for (b in msg) {
        inner.add(b)
    }
    let innerHash = sha256(inner.toArray())
    for (b in innerHash) {
        outer.add(b)
    }
    return sha256(outer.toArray())
}

// 把字节序列转成小写十六进制字符串。
//
// 用 `Array<UInt8>(2n)` 预分配 + 索引写入、最后 String.fromUtf8 一次成串,避免逐字符
// `s += digits[...]` 的 O(n²) 串重建 —— 每个签名 cookie/session 请求都要把 32 字节
// SHA-256 摘要 hex 化一次,对并发 RPS 直接有影响。
func bytesToHex(data: Array<UInt8>): String {
    let digits = "0123456789abcdef".toArray()
    let out = Array<UInt8>(data.size * 2, repeat: UInt8(0))
    var i = 0
    for (b in data) {
        let v = Int64(b)
        out[i] = digits[v / 16]
        out[i + 1] = digits[v % 16]
        i += 2
    }
    return String.fromUtf8(out)
}

// 对外入口:用 key 对 msg 计算 HMAC-SHA256,返回十六进制字符串。这是框架做签名
// Cookie / session 时唯一依赖的签名原语(即"替换缝"的对外契约)。
// 可见性:wen_contrib 的 csrf_test 用它生成有效签名的 cookie 做测试,
// 故 public。等仓颉 stdx.crypto 发布后,文档建议用户应优先用 stdx.crypto.hmac。
public func hmacSha256Hex(key: String, msg: String): String {
    return bytesToHex(hmacSha256(key.toArray(), msg.toArray()))
}

// 定长时间比较两个字符串是否相等(逐字节累积差异,不提前返回),避免按字符逐位
// 比较带来的计时侧信道——用于校验签名等敏感比较。
// 可见性:wen_contrib 的 mw_csrf 在 token 校验路径需要它,故 public。
public func constantTimeEquals(a: String, b: String): Bool {
    let ab = a.toArray()
    let bb = b.toArray()
    if (ab.size != bb.size) {
        return false
    }
    var diff = 0
    var i = 0
    while (i < ab.size) {
        diff = diff | (Int64(ab[i]) ^ Int64(bb[i]))
        i += 1
    }
    return diff == 0
}
