package wen

import std.collection.*

/*
 * 自写的 gzip 压缩(零依赖)。
 *
 * 替换缝(REPLACEMENT SEAM)
 * --------------------------
 * 标准库无压缩实现(gzip/zlib 在扩展库 stdx.compress 里,当前未安装),故这里按
 * RFC 1951(DEFLATE)/ RFC 1952(gzip 容器)自行实现一个压缩器。框架其余部分只通过
 * 唯一入口 `gzipCompress(data): Array<UInt8>` 使用它;日后若装好 stdx,只需重写本文件、
 * 保持该签名,compression() 中间件无需改动。
 *
 * 实现采用「固定哈夫曼码 + 贪心 LZ77(哈希链查找)」:产出的是完全合规的 DEFLATE 流,
 * 任意客户端(浏览器、curl --compressed、gunzip)都能解压。压缩率不如 zlib 的动态
 * 哈夫曼,但实现简单、正确、零依赖,足以满足「按 Accept-Encoding 压缩文本响应」的需求。
 *
 * DEFLATE 比特序约定:数据元素(如各类 extra bits、stored 块长度)按低位在前打包;
 * 哈夫曼码则按高位在前传输——因此对哈夫曼码先做按位反转,再用「低位在前」的写入器
 * 输出,即得到正确的高位在前序。
 */

// 长度码(257..285)对应的基值与 extra 位数(共 29 项)。
let LEN_BASE: Array<Int64> = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
let LEN_EXTRA: Array<Int64> = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

// 距离码(0..29)对应的基值与 extra 位数(共 30 项)。
let DIST_BASE: Array<Int64> = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
let DIST_EXTRA: Array<Int64> = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

// 「低位在前」的比特写入器:writeBits 把 value 的低 n 位依次塞入输出流。
class BitWriter {
    let out = ArrayList<UInt8>()
    var bitBuf: Int64 = 0
    var bitCnt: Int64 = 0

    func writeBits(value: Int64, n: Int64): Unit {
        bitBuf = bitBuf | ((value & ((1 << n) - 1)) << bitCnt)
        bitCnt += n
        while (bitCnt >= 8) {
            out.add(UInt8(bitBuf & 0xFF))
            bitBuf = bitBuf >> 8
            bitCnt -= 8
        }
    }

    // 补齐到字节边界(残留不足 8 位的也输出)。
    func flush(): Unit {
        if (bitCnt > 0) {
            out.add(UInt8(bitBuf & 0xFF))
            bitBuf = 0
            bitCnt = 0
        }
    }
}

// 反转 code 的低 len 位(把高位在前的哈夫曼码转成可用低位在前写入器输出的形式)。
func reverseBits(code: Int64, len: Int64): Int64 {
    var r = 0
    var c = code
    var i = 0
    while (i < len) {
        r = (r << 1) | (c & 1)
        c = c >> 1
        i += 1
    }
    return r
}

// 用固定哈夫曼表输出一个「字面量/长度」符号(0..287)。
func emitLit(bw: BitWriter, sym: Int64): Unit {
    var code = 0
    var len = 0
    if (sym <= 143) {
        code = 0x30 + sym; len = 8
    } else if (sym <= 255) {
        code = 0x190 + (sym - 144); len = 9
    } else if (sym <= 279) {
        code = sym - 256; len = 7
    } else {
        code = 0xC0 + (sym - 280); len = 8
    }
    bw.writeBits(reverseBits(code, len), len)
}

// 输出一个固定哈夫曼的「距离」符号(0..29,定长 5 位)。
func emitDist(bw: BitWriter, dcode: Int64): Unit {
    bw.writeBits(reverseBits(dcode, 5), 5)
}

// 由匹配长度求长度码及其 extra(返回 码, extra位数, extra值)。
func lengthCode(len: Int64): (Int64, Int64, Int64) {
    var k = LEN_BASE.size - 1
    while (k > 0 && LEN_BASE[k] > len) {
        k -= 1
    }
    return (257 + k, LEN_EXTRA[k], len - LEN_BASE[k])
}

// 由匹配距离求距离码及其 extra(返回 码, extra位数, extra值)。
func distanceCode(dist: Int64): (Int64, Int64, Int64) {
    var k = DIST_BASE.size - 1
    while (k > 0 && DIST_BASE[k] > dist) {
        k -= 1
    }
    return (k, DIST_EXTRA[k], dist - DIST_BASE[k])
}

// 取 data[pos..pos+3) 的 3 字节哈希(用于 LZ77 查找,pos+2 必须在界内)。
func hash3(data: Array<UInt8>, pos: Int64): Int64 {
    let a = Int64(data[pos])
    let b = Int64(data[pos + 1])
    let c = Int64(data[pos + 2])
    return ((a << 10) ^ (b << 5) ^ c) & 0x7FFF      // 15 位哈希
}

// 把 data 用固定哈夫曼 + 贪心 LZ77 编码为单个 DEFLATE 块(BFINAL=1, BTYPE=01)。
func deflateFixed(data: Array<UInt8>, bw: BitWriter): Unit {
    let n = data.size
    bw.writeBits(1, 1)       // BFINAL = 1(最后一个块)
    bw.writeBits(1, 2)       // BTYPE = 01(固定哈夫曼)

    let minMatch = 3
    let maxMatch = 258
    let window = 32768
    let maxChain = 128

    let head = Array<Int64>(32768, repeat: -1)   // 哈希 -> 最近位置
    let prev = Array<Int64>(if (n > 0) { n } else { 1 }, repeat: -1)  // 同哈希的更早位置链

    var i = 0
    while (i < n) {
        var matchLen = 0
        var matchDist = 0
        if (i + minMatch <= n) {
            let h = hash3(data, i)
            var cand = head[h]
            var chain = 0
            while (cand >= 0 && cand >= i - window && chain < maxChain) {
                var l = 0
                while (l < maxMatch && i + l < n && data[cand + l] == data[i + l]) {
                    l += 1
                }
                if (l > matchLen) {
                    matchLen = l
                    matchDist = i - cand
                    if (l >= maxMatch) {
                        break
                    }
                }
                cand = prev[cand]
                chain += 1
            }
        }

        if (matchLen >= minMatch) {
            // 输出长度/距离对。
            let (lc, leb, lev) = lengthCode(matchLen)
            emitLit(bw, lc)
            if (leb > 0) {
                bw.writeBits(lev, leb)
            }
            let (dc, deb, dev) = distanceCode(matchDist)
            emitDist(bw, dc)
            if (deb > 0) {
                bw.writeBits(dev, deb)
            }
            // 为被匹配跨过的每个位置插入哈希(供后续匹配引用),再前进。
            let end = i + matchLen
            while (i < end) {
                if (i + minMatch <= n) {
                    let h2 = hash3(data, i)
                    prev[i] = head[h2]
                    head[h2] = i
                }
                i += 1
            }
        } else {
            emitLit(bw, Int64(data[i]))
            if (i + minMatch <= n) {
                let h2 = hash3(data, i)
                prev[i] = head[h2]
                head[h2] = i
            }
            i += 1
        }
    }
    emitLit(bw, 256)         // 块结束符
}

// CRC-32(gzip 所用,多项式 0xEDB88320),按位实现。
func crc32(data: Array<UInt8>): UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for (b in data) {
        crc = crc ^ UInt32(b)
        var j = 0
        while (j < 8) {
            if ((crc & UInt32(1)) != UInt32(0)) {
                crc = (crc >> 1) ^ UInt32(0xEDB88320)
            } else {
                crc = crc >> 1
            }
            j += 1
        }
    }
    return crc ^ UInt32(0xFFFFFFFF)
}

// 把一个 UInt32 以小端序追加到 out。
func writeLE32(out: ArrayList<UInt8>, v: UInt32): Unit {
    out.add(UInt8(v & UInt32(0xFF)))
    out.add(UInt8((v >> 8) & UInt32(0xFF)))
    out.add(UInt8((v >> 16) & UInt32(0xFF)))
    out.add(UInt8((v >> 24) & UInt32(0xFF)))
}

// 对外入口:把 data 压缩成 gzip 字节流(RFC 1952 容器 + DEFLATE 数据)。
public func gzipCompress(data: Array<UInt8>): Array<UInt8> {
    let bw = BitWriter()
    deflateFixed(data, bw)
    bw.flush()

    let out = ArrayList<UInt8>()
    // gzip 头部(10 字节):魔数 1f 8b、CM=08(deflate)、FLG=0、MTIME=0、XFL=0、OS=ff。
    out.add(UInt8(0x1f)); out.add(UInt8(0x8b)); out.add(UInt8(0x08)); out.add(UInt8(0x00))
    out.add(UInt8(0x00)); out.add(UInt8(0x00)); out.add(UInt8(0x00)); out.add(UInt8(0x00))
    out.add(UInt8(0x00)); out.add(UInt8(0xff))
    // DEFLATE 数据。
    for (b in bw.out) {
        out.add(b)
    }
    // 尾部:CRC-32(原始数据)+ ISIZE(原始长度 mod 2^32),均小端。
    writeLE32(out, crc32(data))
    writeLE32(out, UInt32(data.size & 0xFFFFFFFF))
    return out.toArray()
}
