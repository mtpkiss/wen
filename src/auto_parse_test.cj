package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 验证请求体 / Cookie 解析是「内置」的:**不注册任何 parser 中间件**,
// req.json() / req.attribute() / req.file() / req.cookie() 仍按 Content-Type 自动解析。
@Test
class AutoParseTest {
    // JSON:不注册 jsonParser,req.json() 仍自动解析。
    @TestCase
    func testJsonAutoParsed(): Unit {
        let app = wen()
        app.post(
            "/u",
            {
                req: HttpRequest, res: HttpResponse =>
                    let name = match (req.json()) {
                        case Some(j) => match (j.get("name")) {
                            case Some(v) => v.asString() ?? "?";
                            case None => "?"
                        }
                        case None => "none"
                    }
                    res.send(name)
            }
        )
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "application/json"
        req.body = "{\"name\":\"bob\"}"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "bob")
    }

    // 非法 JSON 不让请求失败,req.json() 为 None(与显式 jsonParser 行为一致)。
    @TestCase
    func testJsonAutoMalformedIsNone(): Unit {
        let app = wen()
        app.post("/u", {
            req: HttpRequest, res: HttpResponse => res.send(match (req.json()) {
                case Some(_) => "yes";
                case None => "no"
            })
        })
        let req = HttpRequest("POST", "/u");
        req.path = "/u"
        req.headers["content-type"] = "application/json"
        req.body = "{bad"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "no")
    }

    // 表单:不注册 urlencodedParser,req.attribute() 仍自动解析出字段。
    @TestCase
    func testUrlencodedAutoParsed(): Unit {
        let app = wen()
        app.post("/f", {
            req: HttpRequest, res: HttpResponse => res.send(req.attribute("city") ?? "none")
        })
        let req = HttpRequest("POST", "/f");
        req.path = "/f"
        req.headers["content-type"] = "application/x-www-form-urlencoded"
        req.body = "city=hangzhou&n=1"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "hangzhou")
    }

    // Cookie:不注册 cookieParser,req.cookie() 仍自动解析。
    @TestCase
    func testCookieAutoParsed(): Unit {
        let app = wen()
        app.get("/c", {
            req: HttpRequest, res: HttpResponse => res.send(req.cookie("sid") ?? "none")
        })
        let req = HttpRequest("GET", "/c");
        req.path = "/c"
        req.headers["cookie"] = "sid=abc; theme=dark"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "abc")
    }

    // multipart:不注册 multipart(),req.file() 仍自动解析。
    @TestCase
    func testMultipartAutoParsed(): Unit {
        let boundary = "----WenAuto"
        let buf = ArrayList<UInt8>()
        let raw = "--${boundary}\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n\r\nAB\r\n--${boundary}--\r\n"
        for (b in raw.toArray()) {
            buf.add(b)
        }
        let app = wen()
        app.post("/up", {
            req: HttpRequest, res: HttpResponse => match (req.file("f")) {
                case Some(uf) => res.send("${uf.filename}:${uf.size()}")
                case None => res.send("none")
            }
        })
        let req = HttpRequest("POST", "/up");
        req.path = "/up"
        req.headers["content-type"] = "multipart/form-data; boundary=${boundary}"
        req.bodyBytes = buf.toArray()
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "a.txt:2")
    }

    // 同时被中间件「提前触发」与访问器「按需触发」也不会重复解析(multipart 不会重复加文件)。
    @TestCase
    func testNoDoubleParseWithMiddleware(): Unit {
        let boundary = "B2"
        let buf = ArrayList<UInt8>()
        let raw = "--${boundary}\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.txt\"\r\n\r\nZ\r\n--${boundary}--\r\n"
        for (b in raw.toArray()) {
            buf.add(b)
        }
        let app = wen()
        app.use(multipart())
        app.post(
            "/up",
            {
                req: HttpRequest, res: HttpResponse =>
                    req.file("f") // 再次触发:应被闸门拦下,不重复解析
                    res.send("${req.files.size}")
            }
        )
        let req = HttpRequest("POST", "/up");
        req.path = "/up"
        req.headers["content-type"] = "multipart/form-data; boundary=${boundary}"
        req.bodyBytes = buf.toArray()
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.body == "1")
    }
}
