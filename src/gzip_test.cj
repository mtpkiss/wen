package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// ---- 测试内自带的最小 inflater(仅支持本编码器会产出的「固定哈夫曼 / stored」块),
//      用于自洽地验证 gzipCompress 的输出能被正确解压回原文。--------------------
class GzBitReader {
    let data: Array<UInt8>
    var pos: Int64
    var bitBuf: Int64 = 0
    var bitCnt: Int64 = 0
    init(data: Array<UInt8>, start: Int64) {
        this.data = data
        this.pos = start
    }
    func readBit(): Int64 {
        if (bitCnt == 0) {
            bitBuf = Int64(data[pos]); pos += 1; bitCnt = 8
        }
        let b = bitBuf & 1
        bitBuf = bitBuf >> 1
        bitCnt -= 1
        return b
    }
    func readBits(n: Int64): Int64 {
        var v = 0; var i = 0
        while (i < n) { v = v | (readBit() << i); i += 1 }
        return v
    }
    func alignByte(): Unit { bitCnt = 0 }
}

func decodeFixedSym(br: GzBitReader): Int64 {
    var code = 0; var len = 0
    while (len < 7) { code = (code << 1) | br.readBit(); len += 1 }
    if (code <= 23) { return 256 + code }
    code = (code << 1) | br.readBit()
    if (code >= 48 && code <= 191) { return code - 48 }
    if (code >= 192 && code <= 199) { return 280 + (code - 192) }
    code = (code << 1) | br.readBit()
    return 144 + (code - 400)
}

// 解压一个 gzip 字节流(假定 FLG=0,头部固定 10 字节)。
func inflateGzip(gz: Array<UInt8>): Array<UInt8> {
    let br = GzBitReader(gz, 10)
    let out = ArrayList<UInt8>()
    while (true) {
        let bfinal = br.readBit()
        let btype = br.readBits(2)
        if (btype == 0) {
            br.alignByte()
            let len = br.readBits(16)
            br.readBits(16)                 // NLEN(忽略)
            var i = 0
            while (i < len) { out.add(UInt8(br.readBits(8))); i += 1 }
        } else if (btype == 1) {
            while (true) {
                let sym = decodeFixedSym(br)
                if (sym == 256) { break }
                if (sym < 256) {
                    out.add(UInt8(sym))
                } else {
                    let length = LEN_BASE[sym - 257] + br.readBits(LEN_EXTRA[sym - 257])
                    var dcode = 0; var k = 0
                    while (k < 5) { dcode = (dcode << 1) | br.readBit(); k += 1 }
                    let dist = DIST_BASE[dcode] + br.readBits(DIST_EXTRA[dcode])
                    var m = 0
                    while (m < length) { out.add(out[out.size - dist]); m += 1 }
                }
            }
        } else {
            break
        }
        if (bfinal == 1) { break }
    }
    return out.toArray()
}

func bytesEqual(a: Array<UInt8>, b: Array<UInt8>): Bool {
    if (a.size != b.size) { return false }
    var i = 0
    while (i < a.size) {
        if (a[i] != b[i]) { return false }
        i += 1
    }
    return true
}

@Test
class GzipTest {
    // CRC-32 已知向量。
    @TestCase
    func testCrc32Vectors(): Unit {
        @Assert(crc32("".toArray()) == UInt32(0))
        @Assert(crc32("123456789".toArray()) == UInt32(0xCBF43926))
    }

    // gzip 容器结构:魔数 + CM,以及尾部 ISIZE = 原始长度。
    @TestCase
    func testGzipStructure(): Unit {
        let raw = "hello world".toArray()
        let gz = gzipCompress(raw)
        @Assert(gz[0] == UInt8(0x1f))
        @Assert(gz[1] == UInt8(0x8b))
        @Assert(gz[2] == UInt8(0x08))
        // 末 4 字节小端 = ISIZE。
        let n = gz.size
        let isize = Int64(gz[n - 4]) | (Int64(gz[n - 3]) << 8) | (Int64(gz[n - 2]) << 16) | (Int64(gz[n - 1]) << 24)
        @Assert(isize == raw.size)
    }

    // 压缩 -> 解压 往返一致(覆盖空串、短串、含字面量与匹配的重复串)。
    @TestCase
    func testRoundTrip(): Unit {
        let cases = ["", "a", "hello", "The quick brown fox jumps over the lazy dog",
                     "你好,世界!Wen gzip 中文测试。"]
        for (s in cases) {
            let raw = s.toArray()
            @Assert(bytesEqual(inflateGzip(gzipCompress(raw)), raw))
        }
    }

    // 大量重复内容应被显著压缩,且能解压回原文。
    @TestCase
    func testRepetitiveCompresses(): Unit {
        var s = ""
        var i = 0
        while (i < 200) { s += "abcdefgh"; i += 1 }    // 1600 字节,强可压缩
        let raw = s.toArray()
        let gz = gzipCompress(raw)
        @Assert(gz.size < raw.size / 4)                 // 至少压到原来的 1/4 以下
        @Assert(bytesEqual(inflateGzip(gz), raw))
    }

    // compression() 中间件:客户端接受 gzip 时压缩文本响应,且能解压回原文。
    @TestCase
    func testMiddlewareCompresses(): Unit {
        var tmp = ""
        var i = 0
        while (i < 50) { tmp += "the quick brown fox " ; i += 1 }     // 1000 字节文本
        let body = tmp                                                // 不可变,供闭包捕获
        let app = wen()
        app.use(compression())
        app.get("/", { _: HttpRequest, res: HttpResponse => res.send(body) })

        let req = HttpRequest("GET", "/"); req.path = "/"
        req.headers["accept-encoding"] = "gzip, deflate, br"
        let res = HttpResponse(); app.handle(req, res)

        let enc = match (res.get("Content-Encoding")) { case Some(v) => v; case None => "" }
        @Assert(enc == "gzip")
        match (res.bodyBytes) {
            case Some(gz) => @Assert(bytesEqual(inflateGzip(gz), body.toArray()))
            case None => @Assert(false)
        }
        let vary = match (res.get("Vary")) { case Some(v) => v; case None => "" }
        @Expect(vary.contains("Accept-Encoding"))
    }

    // 客户端不接受 gzip -> 不压缩,响应体保持原样。
    @TestCase
    func testMiddlewareSkipsWithoutAccept(): Unit {
        var tmp = ""
        var i = 0
        while (i < 50) { tmp += "the quick brown fox " ; i += 1 }
        let body = tmp
        let app = wen()
        app.use(compression())
        app.get("/", { _: HttpRequest, res: HttpResponse => res.send(body) })
        let req = HttpRequest("GET", "/"); req.path = "/"   // 无 Accept-Encoding
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body == body)
        match (res.get("Content-Encoding")) { case Some(_) => @Assert(false); case None => @Expect(true) }
    }

    // 小于阈值的响应不压缩。
    @TestCase
    func testMiddlewareSkipsSmall(): Unit {
        let app = wen()
        app.use(compression())
        app.get("/", { _: HttpRequest, res: HttpResponse => res.send("tiny") })
        let req = HttpRequest("GET", "/"); req.path = "/"
        req.headers["accept-encoding"] = "gzip"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body == "tiny")
        match (res.get("Content-Encoding")) { case Some(_) => @Assert(false); case None => @Expect(true) }
    }
}
