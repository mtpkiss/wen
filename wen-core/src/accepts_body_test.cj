package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试 req.acceptsCharsets/Encodings/Languages 内容协商,以及 textParser/rawParser
 * 两个请求体解析中间件。
 */

// 把 ?String 协商结果转成可断言字符串(None 记为 "none")。
func optStr(r: ?String): String {
    match (r) {
        case Some(v) => v
        case None => "none"
    }
}

@Test
class AcceptsNegotiationTest {
    func reqWith(name: String, value: String): HttpRequest {
        let req = HttpRequest("GET", "/x")
        req.headers[name] = value
        return req
    }

    // ---- Accept-Charset ----

    @TestCase
    func testCharsetBestByQ(): Unit {
        let req = reqWith("accept-charset", "utf-8, iso-8859-1;q=0.5")
        @Assert(optStr(req.acceptsCharsets(["iso-8859-1", "utf-8"])) == "utf-8")
    }

    @TestCase
    func testCharsetOnlyOfferedMatches(): Unit {
        let req = reqWith("accept-charset", "utf-8, iso-8859-1;q=0.5")
        @Assert(optStr(req.acceptsCharsets(["iso-8859-1"])) == "iso-8859-1")
    }

    @TestCase
    func testCharsetAbsentHeaderReturnsFirst(): Unit {
        let req = HttpRequest("GET", "/x")
        @Assert(optStr(req.acceptsCharsets(["utf-8", "ascii"])) == "utf-8")
    }

    @TestCase
    func testCharsetRejectedByZeroQ(): Unit {
        let req = reqWith("accept-charset", "utf-8;q=0")
        @Assert(optStr(req.acceptsCharsets(["utf-8"])) == "none")
    }

    @TestCase
    func testCharsetWildcard(): Unit {
        let req = reqWith("accept-charset", "*")
        @Assert(optStr(req.acceptsCharsets(["utf-8"])) == "utf-8")
    }

    @TestCase
    func testCharsetBoolForm(): Unit {
        let req = reqWith("accept-charset", "utf-8")
        @Assert(req.acceptsCharsets("utf-8"))
        @Assert(!req.acceptsCharsets("utf-16"))
    }

    // ---- Accept-Encoding ----

    @TestCase
    func testEncodingBestByQ(): Unit {
        let req = reqWith("accept-encoding", "gzip, deflate;q=0.5")
        @Assert(optStr(req.acceptsEncodings(["deflate", "gzip"])) == "gzip")
    }

    // identity 未被提及时默认可接受。
    @TestCase
    func testEncodingIdentityDefault(): Unit {
        let req = reqWith("accept-encoding", "gzip")
        @Assert(optStr(req.acceptsEncodings(["identity"])) == "identity")
    }

    // *;q=0 显式排除其它(含 identity)。
    @TestCase
    func testEncodingIdentityExcludedByStar(): Unit {
        let req = reqWith("accept-encoding", "gzip, *;q=0")
        @Assert(optStr(req.acceptsEncodings(["identity"])) == "none")
    }

    @TestCase
    func testEncodingAbsentReturnsFirst(): Unit {
        let req = HttpRequest("GET", "/x")
        @Assert(optStr(req.acceptsEncodings(["gzip", "identity"])) == "gzip")
    }

    // ---- Accept-Language ----

    @TestCase
    func testLanguageBestByQ(): Unit {
        let req = reqWith("accept-language", "en-US, en;q=0.8")
        @Assert(optStr(req.acceptsLanguages(["en", "en-US"])) == "en-US")
    }

    // 头里的 "en" 前缀匹配候选 "en-US"。
    @TestCase
    func testLanguagePrefixMatch(): Unit {
        let req = reqWith("accept-language", "en")
        @Assert(optStr(req.acceptsLanguages(["en-US"])) == "en-US")
    }

    @TestCase
    func testLanguageWildcard(): Unit {
        let req = reqWith("accept-language", "*")
        @Assert(optStr(req.acceptsLanguages(["fr"])) == "fr")
    }

    @TestCase
    func testLanguageBoolForm(): Unit {
        let req = reqWith("accept-language", "en-US, fr;q=0.9")
        @Assert(req.acceptsLanguages("fr"))
        @Assert(!req.acceptsLanguages("de"))
    }
}

@Test
class BodyParserExtrasTest {
    func postReq(contentType: String, body: String): HttpRequest {
        let req = HttpRequest("POST", "/x")
        req.headers["content-type"] = contentType
        req.body = body
        req.bodyBytes = body.toArray()
        return req
    }

    func runMw(mw: Middleware, req: HttpRequest): Unit {
        let res = HttpResponse()
        mw(req, res, {=>})
    }

    // textParser:匹配 text/plain 时把文本体放入 "text" 属性。
    @TestCase
    func testTextParserMatches(): Unit {
        let req = postReq("text/plain", "hello world")
        runMw(textParser(), req)
        match (req.attribute("text")) {
            case Some(v) => @Assert(v == "hello world")
            case None => @Assert(false)
        }
    }

    // Content-Type 不匹配 → 不写入。
    @TestCase
    func testTextParserWrongType(): Unit {
        let req = postReq("application/json", "{}")
        runMw(textParser(), req)
        match (req.attribute("text")) {
            case Some(_) => @Assert(false)
            case None => @Assert(true)
        }
    }

    // 自定义匹配类型。
    @TestCase
    func testTextParserCustomType(): Unit {
        let req = postReq("application/xml", "<a/>")
        runMw(textParser(contentType: "application/xml"), req)
        match (req.attribute("text")) {
            case Some(v) => @Assert(v == "<a/>")
            case None => @Assert(false)
        }
    }

    // rawParser:匹配时把原始字节放入 "raw" local。
    @TestCase
    func testRawParserMatches(): Unit {
        let req = postReq("application/octet-stream", "abc")
        runMw(rawParser(), req)
        match (req.local("raw")) {
            case Some(v) => match (v as Array<UInt8>) {
                case Some(bytes) => @Assert(bytes.size == 3)
                case None => @Assert(false)
            }
            case None => @Assert(false)
        }
    }

    @TestCase
    func testRawParserWrongType(): Unit {
        let req = postReq("text/plain", "abc")
        runMw(rawParser(), req)
        match (req.local("raw")) {
            case Some(_) => @Assert(false)
            case None => @Assert(true)
        }
    }
}
