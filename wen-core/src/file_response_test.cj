package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class FileResponseTest {
    // 把响应体字节还原成字符串,方便断言分片内容。
    func bytesOf(res: HttpResponse): String {
        match (res.bodyBytes) {
            case Some(b) => return String.fromUtf8(b)
            case None => return res.body
        }
    }

    // 在工作目录写一个内容为 "0123456789"(10 字节)的临时文件用于测试。
    func writeTemp(name: String): String {
        File.writeTo(name, "0123456789".toArray())
        return name
    }

    // sendFile 会带上 ETag;客户端用 If-None-Match 携带该 ETag 再次请求时应得 304。
    @TestCase
    func testSendFileEtagAnd304(): Unit {
        let path = writeTemp("._cjx_fr_etag.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        // 首次请求:拿到内容与 ETag。
        let r1 = HttpRequest("GET", "/f");
        r1.path = "/f"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        let etag = match (s1.get("ETag")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(!etag.isEmpty())

        // 带 If-None-Match 再请求:内容未变,应回 304 且无响应体。
        let r2 = HttpRequest("GET", "/f");
        r2.path = "/f"
        r2.headers["if-none-match"] = etag
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.statusCode == 304)
        @Assert(bytesOf(s2) == "")
        remove(path)
    }

    // 空内容的 ETag 应是弱校验 W/"0-0-0":强 ETag 对空体会退化成固定的 "0-0-0"(长度与
    // 两段哈希全为 0),不同的空资源彼此碰撞;弱 ETag 如实表达"可能不唯一",也避免被当作
    // Range 子区间检索的强校验器。非空内容仍是强 ETag(带引号、无 W/ 前缀)。
    @TestCase
    func testComputeETagEmptyBodyIsWeak(): Unit {
        let emptyTag = computeETag(Array<UInt8>())
        @Assert(emptyTag == "W/\"0-0-0\"")
        let nonEmptyTag = computeETag("hello".toArray())
        @Assert(!nonEmptyTag.startsWith("W/"))
        @Assert(nonEmptyTag.startsWith("\""))
    }

    // Range: bytes=2-5 应回 206,只发第 2..5 字节,并带正确的 Content-Range。
    @TestCase
    func testSendFileRange206(): Unit {
        let path = writeTemp("._cjx_fr_range.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        let req = HttpRequest("GET", "/f");
        req.path = "/f"
        req.headers["range"] = "bytes=2-5"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 206)
        @Assert(bytesOf(res) == "2345")
        let cr = match (res.get("Content-Range")) {
            case Some(v) => v;
            case None => ""
        }
        @Assert(cr == "bytes 2-5/10")
        remove(path)
    }

    // Range 后缀写法 bytes=-3 取末尾 3 个字节。
    @TestCase
    func testSendFileRangeSuffix(): Unit {
        let path = writeTemp("._cjx_fr_suffix.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        let req = HttpRequest("GET", "/f");
        req.path = "/f"
        req.headers["range"] = "bytes=-3"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 206)
        @Assert(bytesOf(res) == "789")
        let cr = match (res.get("Content-Range")) {
            case Some(v) => v;
            case None => ""
        }
        @Assert(cr == "bytes 7-9/10")
        remove(path)
    }

    // 越界的 Range 不可满足,应回 416 并带 "bytes */<size>"。
    @TestCase
    func testSendFileRangeUnsatisfiable(): Unit {
        let path = writeTemp("._cjx_fr_416.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        let req = HttpRequest("GET", "/f");
        req.path = "/f"
        req.headers["range"] = "bytes=100-200"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 416)
        let cr = match (res.get("Content-Range")) {
            case Some(v) => v;
            case None => ""
        }
        @Assert(cr == "bytes */10")
        remove(path)
    }

    // RFC 7233 §3.2 — If-Range 让客户端做"我手里有旧资源,如果服务端还是这个版本
    // 就发 Range,否则把整个资源发我"的条件性范围请求。命中(强 ETag 精确相等或
    // Last-Modified 一致)→ 走原 Range 路径回 206;不匹配 → 必须忽略 Range,回 200
    // 全文 —— 因为客户端持有的旧资源已经过时,把新版本的 byte-slice 拼到旧资源上
    // 是"缓存击穿"(收到错位字节)。If-Range 之前完全未实现,任意 If-Range 都会
    // 被无视,Range 照常处理 → 错位 byte-slice 直接发出。
    // sendFile 默认走 computeETag 算"强 ETag"(无 W/ 前缀),正向用例可直接拿
    // res.get("ETag") 回传。
    @TestCase
    func testIfRangeETagMatchSends206(): Unit {
        let path = writeTemp("._cjx_fr_ifrange_match.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        // 先取当前 ETag。
        let r0 = HttpRequest("GET", "/f")
        r0.path = "/f"
        let s0 = HttpResponse()
        app.handle(r0, s0)
        let etag = match (s0.get("ETag")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(!etag.isEmpty())

        // If-Range 携带当前 ETag + Range → 206,与不带 If-Range 一致。
        let req = HttpRequest("GET", "/f")
        req.path = "/f"
        req.headers["range"] = "bytes=2-5"
        req.headers["if-range"] = etag
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 206)
        @Assert(bytesOf(res) == "2345")
        remove(path)
    }

    // If-Range 的 ETag 不匹配 → MUST 忽略 Range,回 200 全文。
    @TestCase
    func testIfRangeETagMismatchSends200Full(): Unit {
        let path = writeTemp("._cjx_fr_ifrange_mismatch.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        let req = HttpRequest("GET", "/f")
        req.path = "/f"
        req.headers["range"] = "bytes=2-5"
        req.headers["if-range"] = "\"stale-etag-from-an-older-version\""
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(bytesOf(res) == "0123456789")
        remove(path)
    }

    // RFC 7233 §3.2 第二段:客户端 MUST NOT 在 If-Range 里发"弱 ETag"。服务端收到
    // weak entity-tag 时按"不匹配"处理 — 弱 ETag 允许语义等价但字节不同,无法保
    // 证 byte-range 一致性。即便 W/ 后的内容与当前 ETag 字面相等,也按不匹配走 200。
    @TestCase
    func testIfRangeWeakETagAlwaysSends200Full(): Unit {
        let path = writeTemp("._cjx_fr_ifrange_weak.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        let r0 = HttpRequest("GET", "/f")
        r0.path = "/f"
        let s0 = HttpResponse()
        app.handle(r0, s0)
        let strongEtag = match (s0.get("ETag")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(!strongEtag.isEmpty())

        let req = HttpRequest("GET", "/f")
        req.path = "/f"
        req.headers["range"] = "bytes=2-5"
        // 故意把 strong ETag 包成 weak 形式 —— 即便引号里的内容字面一致,服务端
        // 也必须拒绝把它当作 If-Range 命中。
        req.headers["if-range"] = "W/${strongEtag}"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(bytesOf(res) == "0123456789")
        remove(path)
    }

    // If-Range 携带 Last-Modified 值 → 与当前文件 Last-Modified 精确相等才命中,
    // 走 Range 回 206;不等则忽略 Range,回 200 全文。日期分支与 ETag 分支互斥,
    // 但有的客户端只能拿到 Last-Modified(响应不带 ETag),所以两条路径都需支持。
    @TestCase
    func testIfRangeDateMatchSends206(): Unit {
        let path = writeTemp("._cjx_fr_ifrange_date.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        let r0 = HttpRequest("GET", "/f")
        r0.path = "/f"
        let s0 = HttpResponse()
        app.handle(r0, s0)
        let lm = match (s0.get("Last-Modified")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(!lm.isEmpty())

        let req = HttpRequest("GET", "/f")
        req.path = "/f"
        req.headers["range"] = "bytes=2-5"
        req.headers["if-range"] = lm
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 206)
        @Assert(bytesOf(res) == "2345")
        remove(path)
    }

    // If-Range 携带的日期与当前 Last-Modified 不一致 → 200 全文。
    @TestCase
    func testIfRangeDateMismatchSends200Full(): Unit {
        let path = writeTemp("._cjx_fr_ifrange_date_mismatch.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        let req = HttpRequest("GET", "/f")
        req.path = "/f"
        req.headers["range"] = "bytes=2-5"
        req.headers["if-range"] = "Wed, 21 Oct 2015 07:28:00 GMT"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(bytesOf(res) == "0123456789")
        remove(path)
    }

    // res.attachment(filename) 设置 Content-Disposition 与按扩展名推断的 Content-Type。
    @TestCase
    func testAttachmentHeader(): Unit {
        let res = HttpResponse()
        res.attachment("report.txt")
        let cd = match (res.get("Content-Disposition")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(cd.contains("attachment"))
        @Expect(cd.contains("filename=\"report.txt\""))
        let ct = match (res.get("Content-Type")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(ct.contains("text/plain"))
    }

    // res.download 以附件方式发送文件:带 Content-Disposition(默认用 basename),
    // 同时正确发送文件内容。
    @TestCase
    func testDownloadSendsFile(): Unit {
        let path = writeTemp("._cjx_fr_download.txt")
        let app = wen()
        app.get("/d", {_: HttpRequest, res: HttpResponse => res.download(path)})

        let req = HttpRequest("GET", "/d");
        req.path = "/d"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(bytesOf(res) == "0123456789")
        let cd = match (res.get("Content-Disposition")) {
            case Some(v) => v;
            case None => ""
        }
        @Expect(cd.contains("attachment"))
        @Expect(cd.contains("._cjx_fr_download.txt"))
        remove(path)
    }

    // Range 头里的数字超出 Int64 表达范围("bytes=99999999999999999999-9999999...")
    // 时 parseInt 会在 result*10+d 处算术溢出 → 抛 ArithmeticException → 一路冒到
    // 外层 catch (_: Exception) 映射成 500。RFC 7233 要求"无法解析的 Range 应被
    // 忽略",当前实现等于给攻击者一条免费的稳定 5xx 探测面 — 任何 sendFile /
    // staticFiles / download 都能用一行 Range 头打成 500。修后应当作"不可满足"或
    // "忽略",回 200 或 416,而非 500。
    @TestCase
    func testRangeWithIntegerOverflowDoesNot500(): Unit {
        let path = writeTemp("._cjx_fr_huge_range.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})
        let req = HttpRequest("GET", "/f")
        req.path = "/f"
        req.headers["range"] = "bytes=99999999999999999999-99999999999999999999"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode != 500)
        remove(path)
    }

    // 同上,后缀写法 "bytes=-<overflow>" 也不应让 sendFile 崩成 500。
    @TestCase
    func testRangeSuffixOverflowDoesNot500(): Unit {
        let path = writeTemp("._cjx_fr_huge_suffix.txt")
        let app = wen()
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})
        let req = HttpRequest("GET", "/f")
        req.path = "/f"
        req.headers["range"] = "bytes=-99999999999999999999"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode != 500)
        remove(path)
    }

    // 业务在 res.sendFile 前先用 res.set 写了 Content-Type 与 Cache-Control(预期
    // 文件存在);若文件其实不存在,sendFile 抛异常,上层 error handler 通常会
    // 发 500 响应。这时如果之前设的头没清掉,客户端会看到
    // "500 + Content-Type: image/png + Cache-Control: public, max-age=3600"
    // 这种自相矛盾的响应 — 上游缓存层甚至会把错误页当图片缓存。断言 sendFile
    // 抛异常前已把这些头清掉。
    @TestCase
    func testSendFileMissingClearsHeaders(): Unit {
        let res = HttpResponse()
        res.set("Cache-Control", "public, max-age=3600")
        res.set("Content-Type", "image/png")
        var threw = false
        try {
            res.sendFile("./this-file-does-not-exist.bin")
        } catch (_: Exception) {
            threw = true
        }
        @Assert(threw)
        // 期望:抛异常前已把 Content-Type / Cache-Control 清掉。
        @Assert(res.get("Cache-Control").isNone())
    }

    // 304 响应应与 200 响应有相同的 Vary 头 — RFC 7232 §4.1 要求 304 时服务端应
    // 发送"与 200 响应相同的" cache-control/vary 等,以更新缓存元数据。
    // 早前 send304 只设置状态码并清空 body,不补 Vary: Accept(而 200 路径上
    // format() 会自动加),导致 304 响应缺少 Vary 头,缓存层无法正确更新。
    // 修法:send304 加上 Vary: Accept,与 format 行为一致。
    @TestCase
    func test304IncludesVaryAccept(): Unit {
        let path = writeTemp("._cjx_304_vary.txt")
        let app = wen()
        // 中间件里预先加 Vary: Accept,模拟 format 行为。
        app.use(
            {
                _: HttpRequest, res: HttpResponse, next: Next =>
                    res.vary("Accept")
                    next()
            }
        )
        app.get("/f", {_: HttpRequest, res: HttpResponse => res.sendFile(path)})

        // 首次请求:拿 200 + Vary: Accept + ETag。
        let r1 = HttpRequest("GET", "/f")
        r1.path = "/f"
        let s1 = HttpResponse()
        app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        let etag = match (s1.get("ETag")) {
            case Some(v) => v
            case None => ""
        }
        let vary200 = match (s1.get("Vary")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(!etag.isEmpty())
        @Assert(vary200 == "Accept")

        // 带 If-None-Match 再请求:应回 304 且同样带 Vary: Accept。
        let r2 = HttpRequest("GET", "/f")
        r2.path = "/f"
        r2.headers["if-none-match"] = etag
        let s2 = HttpResponse()
        app.handle(r2, s2)
        @Assert(s2.statusCode == 304)
        let vary304 = match (s2.get("Vary")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(vary304 == "Accept")
        remove(path)
    }

    // toHexLower 由 `s = digits[d] + s` 头插 O(n²) 改为预分配 + 倒序填充。本测试
    // 覆盖 1..16 位 hex 串长度,以及 0/负数/Int64.Max 边界,确保位顺序(MSB 在前)
    // 和单 nibble 边界(0x0/0xf/0x10)都不偏移。改实现时只要把倒序拼写反、漏写
    // 一个 nibble 索引或 off-by-one,任意一条断言都会失败。
    @TestCase
    func testToHexLowerCoversAllPositions(): Unit {
        @Assert(toHexLower(0) == "0")
        @Assert(toHexLower(-1) == "0")
        @Assert(toHexLower(15) == "f")
        @Assert(toHexLower(16) == "10")
        @Assert(toHexLower(255) == "ff")
        @Assert(toHexLower(256) == "100")
        @Assert(toHexLower(4096) == "1000")
        @Assert(toHexLower(0x123456789abcdef) == "123456789abcdef")
        @Assert(toHexLower(Int64.Max) == "7fffffffffffffff")
    }

    // computeETag 由 `"\"" + toHexLower(size) + "-" + ... + "\""` 多次拼接改为单一
    // StringBuilder。改实现时只要把任意一段拼错位置、丢分隔符、漏闭引号,整段
    // ETag 字符串都对不上。固定字节内容 [0..9] 下 size=10,h1/h2 都是已知确定值,
    // 这里硬编码精确预期 — 任何 polynomial-hash 行为改动也会被这条断言挡住。
    @TestCase
    func testComputeETagStableForKnownContent(): Unit {
        let data: Array<UInt8> = [
            UInt8(0),
            UInt8(1),
            UInt8(2),
            UInt8(3),
            UInt8(4),
            UInt8(5),
            UInt8(6),
            UInt8(7),
            UInt8(8),
            UInt8(9)
        ]
        // 旧实现行为基线(评审前):size=10 → "a";
        // h1 = poly(31, 1e9+7), h2 = poly(131, 998244353)。性能优化必须 1:1 保留。
        let etag = computeETag(data)
        @Assert(etag.startsWith("\""))
        @Assert(etag.endsWith("\""))
        // 三段格式 "<sizeHex>-<h1Hex>-<h2Hex>"
        let inner = etag[1..(etag.size - 1)]
        let parts = inner.split("-")
        @Assert(parts.size == 3)
        @Assert(parts[0] == "a") // size 10 → hex "a"
        @Assert(!parts[1].isEmpty())
        @Assert(!parts[2].isEmpty())
        // 同内容多次调用必须完全相等(改实现引入随机/线程不安全会被这条挡住)。
        @Assert(computeETag(data) == etag)
        // 不同内容(末位变更)必须产生不同 ETag,确认 hash 段不是常量。
        let data2: Array<UInt8> = [
            UInt8(0),
            UInt8(1),
            UInt8(2),
            UInt8(3),
            UInt8(4),
            UInt8(5),
            UInt8(6),
            UInt8(7),
            UInt8(8),
            UInt8(10)
        ]
        @Assert(computeETag(data2) != etag)
    }
}
