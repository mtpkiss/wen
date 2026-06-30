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

    // RFC 2046 §5.1.1:位于 body 起始处的首个 boundary 不要求前置 CRLF(它前面没有 part)。
    // 构造首边界紧贴 body 起始(偏移 0、无前导 CRLF、无 preamble)的请求体,验证字段仍能
    // 正确解析 —— 锁住解析器对"首边界省略前导 CRLF"这一合法形态的支持。
    @TestCase
    func testFirstBoundaryAtBodyStartNoLeadingCRLF(): Unit {
        let boundary = "X"
        let buf = ArrayList<UInt8>()
        appendStr(buf, "--${boundary}\r\n") // 首边界在偏移 0,前面没有 CRLF
        appendStr(buf, "Content-Disposition: form-data; name=\"k\"\r\n\r\n")
        appendStr(buf, "v\r\n")
        appendStr(buf, "--${boundary}--\r\n")

        let app = wen()
        app.use(multipart())
        app.post("/u", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let req = HttpRequest("POST", "/u")
        req.path = "/u"
        req.headers["content-type"] = "multipart/form-data; boundary=${boundary}"
        req.bodyBytes = buf.toArray()
        let res = HttpResponse()
        app.handle(req, res)
        let k = match (req.attribute("k")) {
            case Some(v) => v
            case None => ""
        }
        @Assert(k == "v")
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

    // 上传文件名含 "../../../etc/passwd" 这种路径遍历模式:multipart 解析必须把
    // UploadedFile.filename 归一为 basename(只保留最后一段,剥掉所有 "/"),避免
    // 业务代码用直觉写法 `file.saveTo("uploads/" + file.filename)` 直接写出沙箱外。
    // 客户端发的 "../../../etc/passwd" 应被解析为 "passwd"。
    @TestCase
    func testFilenameStripsForwardSlash(): Unit {
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"f\"; filename=\"../../../etc/passwd\"\r\n" +
            "Content-Type: text/plain\r\n\r\n" + "evil\r\n" + "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/upload")
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        match (req.file("f")) {
            case Some(f) => @Assert(f.filename == "passwd")
            case None => @Assert(false)
        }
    }

    // 同上,Windows 风格的反斜杠 "..\..\evil.txt" 也必须被剥成 basename。仓颉运行
    // 在双平台,文件名规范化要同时处理 "/" 和 "\",否则 Windows 部署会有等价的
    // 穿越面。
    @TestCase
    func testFilenameStripsBackslash(): Unit {
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"f\"; filename=\"..\\..\\evil.txt\"\r\n" +
            "Content-Type: text/plain\r\n\r\n" + "x\r\n" + "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/upload")
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        match (req.file("f")) {
            case Some(f) => @Assert(f.filename == "evil.txt")
            case None => @Assert(false)
        }
    }

    // multipart part 的 Content-Disposition 头里,引号包起的 name 值 "a; b" 中含分
    // 号 — 解析器必须按 quote-aware 切分,识别出引号边界,不能在引号内的分号上切
    // 坏(把字段名误切成 "a" 与 "b\"" 两段)。断言带分号的字段名能正确解析回
    // attribute 表。
    @TestCase
    func testFieldNameWithSemicolonInQuotes(): Unit {
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"a; b\"\r\n\r\n" + "value\r\n" +
            "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/")
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        match (req.attribute("a; b")) {
            case Some(v) => @Assert(v == "value")
            case None => @Assert(false)
        }
    }

    // Content-Type 参数串 "multipart/form-data; foo=boundary=fake; boundary=real":
    // 若 boundary 提取用 `indexOf("boundary=")` 子串匹配,会被前面参数 foo 的值
    // (恰好含 "boundary=" 子串)误命中,取出伪 boundary "fake",而真 body 用
    // "real" 分隔。除了让本端解析不出任何 part 外,更严重的是与上游代理 / WAF 的
    // 参数列表解析(按 quote-aware splitter 取 boundary 参数)产生分歧 — 上游
    // 验过的字段集与后端实际解析出的字段集不同,WAF 绕过的硬入口。
    // 修法:用 quote-aware splitter 切参数列表,逐项匹配 k=="boundary"。
    @TestCase
    func testBoundaryNotConfusedByOtherParamValue(): Unit {
        let body = "--real\r\n" + "Content-Disposition: form-data; name=\"k\"\r\n\r\n" + "v\r\n" + "--real--\r\n"
        let req = HttpRequest("POST", "/")
        req.headers["content-type"] = "multipart/form-data; foo=boundary=fake; boundary=real"
        req.bodyBytes = body.toArray()
        // 期望:wen 用真正的 boundary "real" 解析,字段 k=v 进入 attributes。
        match (req.attribute("k")) {
            case Some(v) => @Assert(v == "v")
            case None => @Assert(false)
        }
    }

    // RFC 2046 §5.1.1:真正的 boundary 前必须有 CRLF(body 起始除外)。攻击者
    // 上传文件,在文件内容里嵌入字面 "--BOUNDARY--" 字节序列 — 若解析器只按
    // "--BOUNDARY" 子串扫描而不要求前置 CRLF,会把文件内容中的伪 boundary 当作
    // 真分隔符:后续合法的 part(token / 业务字段)在解析时"凭空消失",业务以
    // 为表单不完整、走默认分支;同时与上游代理(按规范要求前置 CRLF)的解析视
    // 图分歧,构成 multipart 走私基底。
    //
    // 这条断言构造一个文件 part(内容里塞 "--BOUNDARY--more")+ 一个字段 part:
    // 修后应正确解析出 1 个文件 + 字段 k=v。
    @TestCase
    func testBoundaryRequiresCrlfPrefix(): Unit {
        let body = "--BOUNDARY\r\n" + "Content-Disposition: form-data; name=\"f\"; filename=\"x.txt\"\r\n" +
            "Content-Type: text/plain\r\n\r\n" + "AAA--BOUNDARY--more\r\n" + "--BOUNDARY\r\n" +
            "Content-Disposition: form-data; name=\"k\"\r\n\r\n" + "v\r\n" + "--BOUNDARY--\r\n"
        let req = HttpRequest("POST", "/")
        req.headers["content-type"] = "multipart/form-data; boundary=BOUNDARY"
        req.bodyBytes = body.toArray()
        // req.file 触发 ensureBody — 直接读 req.files 字段不会触发懒解析。
        match (req.file("f")) {
            case Some(_) => @Assert(true)
            case None => @Assert(false)
        }
        @Assert(req.files.size == 1)
        @Assert(req.attribute("k") == Some("v"))
    }
}
