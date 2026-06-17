package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MultipartTest {
    func appendStr(buf: ArrayList<UInt8>, s: String): Unit {
        for (b in s.toArray()) {
            buf.add(b)
        }
    }

    // 解析一个含文本字段 + 二进制文件的 multipart 请求体。
    @TestCase
    func testFileAndField(): Unit {
        let boundary = "----WenBoundary123"
        let buf = ArrayList<UInt8>()
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"title\"\r\n\r\n")
        appendStr(buf, "Hello 世界\r\n")
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\n")
        appendStr(buf, "Content-Type: image/png\r\n\r\n")
        // 含 0x00 与 0xFF 的二进制内容,验证逐字节完好(非法 UTF-8)。
        buf.add(UInt8(137));
        buf.add(UInt8(0));
        buf.add(UInt8(255));
        buf.add(UInt8(80))
        appendStr(buf, "\r\n")
        appendStr(buf, "--${boundary}--\r\n")

        let app = wen()
        app.use(multipart())
        app.post("/upload", {_: HttpRequest, res: HttpResponse => res.send("ok")})

        let req = HttpRequest("POST", "/upload");
        req.path = "/upload"
        req.headers["content-type"] = "multipart/form-data; boundary=${boundary}"
        req.bodyBytes = buf.toArray()
        let res = HttpResponse();
        app.handle(req, res)

        // 文本字段(含多字节 UTF-8)进入 attributes。
        let title = match (req.attribute("title")) {
            case Some(v) => v;
            case None => ""
        }
        @Assert(title == "Hello 世界")

        // 文件元数据与字节逐一核对。
        match (req.file("avatar")) {
            case Some(f) =>
                @Assert(f.filename == "a.png")
                @Assert(f.contentType == "image/png")
                @Assert(f.size() == 4)
                @Assert(f.bytes[0] == UInt8(137))
                @Assert(f.bytes[1] == UInt8(0))
                @Assert(f.bytes[2] == UInt8(255))
                @Assert(f.bytes[3] == UInt8(80))
            case None => @Assert(false)
        }
    }

    // 多个文件 + 仅文本字段时 file() 返回 None。
    @TestCase
    func testMultipleAndMissing(): Unit {
        let boundary = "B"
        let buf = ArrayList<UInt8>()
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"docs\"; filename=\"x.txt\"\r\n\r\n")
        appendStr(buf, "AAA\r\n")
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"docs\"; filename=\"y.txt\"\r\n\r\n")
        appendStr(buf, "BBBB\r\n")
        appendStr(buf, "--${boundary}--\r\n")

        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=${boundary}"
        req.bodyBytes = buf.toArray()
        let app = wen();
        app.use(multipart())
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let res = HttpResponse();
        app.handle(req, res)

        @Assert(req.files.size == 2)
        // file() 取同名第一个。
        match (req.file("docs")) {
            case Some(f) =>
                @Assert(f.filename == "x.txt")
                @Assert(f.text() == "AAA")
            case None => @Assert(false)
        }
        match (req.file("nope")) {
            case Some(_) => @Assert(false)
            case None => @Expect(true)
        }
    }

    // 非 multipart 请求原样放行,files 为空。
    @TestCase
    func testNonMultipartPassthrough(): Unit {
        let app = wen()
        app.use(multipart())
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "application/json"
        req.body = "{}"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "ok")
        @Assert(req.files.size == 0)
    }

    // boundary 含引号也能解析。
    @TestCase
    func testQuotedBoundary(): Unit {
        let boundary = "abc123"
        let buf = ArrayList<UInt8>()
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"k\"\r\n\r\n")
        appendStr(buf, "v\r\n")
        appendStr(buf, "--${boundary}--\r\n")

        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=\"${boundary}\""
        req.bodyBytes = buf.toArray()
        let app = wen();
        app.use(multipart())
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(req.attribute("k") == Some("v"))
    }

    // 构造一个含多个文件 + 文本字段的 multipart body,供 limits / fileFilter 用例复用。
    func buildMixedBody(boundary: String): Array<UInt8> {
        let buf = ArrayList<UInt8>()
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"note\"\r\n\r\n")
        appendStr(buf, "hi\r\n")
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"img\"; filename=\"a.png\"\r\n")
        appendStr(buf, "Content-Type: image/png\r\n\r\n")
        appendStr(buf, "AAAAAAAA\r\n") // 8 字节
        appendStr(buf, "--${boundary}\r\n")
        appendStr(buf, "Content-Disposition: form-data; name=\"doc\"; filename=\"b.exe\"\r\n")
        appendStr(buf, "Content-Type: application/octet-stream\r\n\r\n")
        appendStr(buf, "BBB\r\n")
        appendStr(buf, "--${boundary}--\r\n")
        return buf.toArray()
    }

    // 单文件超 maxFileSize -> 413,handler 不会执行。
    @TestCase
    func testMaxFileSizeExceededRejects413(): Unit {
        let app = wen()
        // a.png 是 8 字节,设上限 4 -> 必触发。
        app.use(multipart(maxFileSize: 4))
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=B"
        req.bodyBytes = buildMixedBody("B")
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 413)
        @Assert(res.body != "ok")
    }

    // 单文件等于上限不超 -> 放行,文件正常加入。
    @TestCase
    func testMaxFileSizeAtBoundaryPasses(): Unit {
        let app = wen()
        app.use(multipart(maxFileSize: 8)) // a.png 恰好 8 字节
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=B"
        req.bodyBytes = buildMixedBody("B")
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(req.files.size == 2)
    }

    // 文件数量超 maxFiles -> 413(body 含 2 个文件,上限设 1)。
    @TestCase
    func testMaxFilesExceededRejects413(): Unit {
        let app = wen()
        app.use(multipart(maxFiles: 1))
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=B"
        req.bodyBytes = buildMixedBody("B")
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 413)
    }

    // 字段数(文件 + 文本)超 maxFields -> 413(body 共 3 项,上限设 2)。
    @TestCase
    func testMaxFieldsExceededRejects413(): Unit {
        let app = wen()
        app.use(multipart(maxFields: 2))
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=B"
        req.bodyBytes = buildMixedBody("B")
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 413)
    }

    // fileFilter 拒绝某 contentType:被拒文件静默丢弃,不算超额,handler 正常执行。
    @TestCase
    func testFileFilterSilentlyDropsRejected(): Unit {
        let app = wen()
        // 只接收 image/* —— b.exe 的 octet-stream 应被丢弃,a.png 保留。
        app.use(multipart(fileFilter: {
            _: String, _: String, ctype: String => ctype.startsWith("image/")
        }))
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=B"
        req.bodyBytes = buildMixedBody("B")
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(req.files.size == 1)
        match (req.file("img")) {
            case Some(f) => @Assert(f.contentType == "image/png")
            case None => @Assert(false)
        }
        // 被丢弃的文件不出现。
        match (req.file("doc")) {
            case Some(_) => @Assert(false)
            case None => @Expect(true)
        }
    }

    // 默认无参 multipart() 无任何上限,行为与旧接口一致。
    @TestCase
    func testNoOptionsDefaultsToUnlimited(): Unit {
        let app = wen()
        app.use(multipart()) // 无 limits
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=B"
        req.bodyBytes = buildMixedBody("B")
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(req.files.size == 2)
    }

    // saveTo 落盘后内容与上传字节一致。
    @TestCase
    func testSaveTo(): Unit {
        let f = UploadedFile("a", "a.bin", "application/octet-stream", [UInt8(1), UInt8(2), UInt8(3), UInt8(250)])
        let path = "._cjx_upload_save.bin"
        f.saveTo(path)
        let back = File.readFrom(path)
        @Assert(back.size == 4)
        @Assert(back[3] == UInt8(250))
        remove(path)
    }
}
