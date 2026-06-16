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
}
