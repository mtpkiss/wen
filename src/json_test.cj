package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonTest {
    // ---- small extraction helpers (avoid relying on Option combinators) -----
    func si(v: JsonValue): Int64 {
        match (v.asInt()) { case Some(n) => n; case None => -999 }
    }
    func ss(v: JsonValue): String {
        match (v.asString()) { case Some(s) => s; case None => "<none>" }
    }
    func field(v: JsonValue, k: String): JsonValue {
        match (v.get(k)) { case Some(x) => x; case None => JsonNull }
    }
    func elem(v: JsonValue, i: Int64): JsonValue {
        match (v.at(i)) { case Some(x) => x; case None => JsonNull }
    }

    // Scalars parse to the matching kind with the right accessor.
    @TestCase
    func testParseScalars(): Unit {
        @Assert(si(parseJson("42")) == 42)
        @Assert(si(parseJson("-7")) == -7)
        @Assert(parseJson("true").asBool() ?? false)
        @Assert(!(parseJson("false").asBool() ?? true))
        @Assert(parseJson("null").isNull())
        @Assert(ss(parseJson("\"hi\"")) == "hi")
    }

    // A float lexeme is preserved and reads back as a Float64.
    @TestCase
    func testParseFloat(): Unit {
        match (parseJson("3.14").asFloat()) {
            case Some(f) => @Assert(f > 3.13 && f < 3.15)
            case None => @Assert(false)
        }
    }

    // Nested object/array navigation via get/at.
    @TestCase
    func testParseNested(): Unit {
        let v = parseJson("{\"user\":{\"name\":\"alice\",\"age\":30},\"tags\":[\"a\",\"b\"]}")
        @Assert(ss(field(field(v, "user"), "name")) == "alice")
        @Assert(si(field(field(v, "user"), "age")) == 30)
        @Assert(ss(elem(field(v, "tags"), 1)) == "b")
        @Assert(field(v, "tags").size() == 2)
    }

    // Escapes and a multi-byte \u sequence decode correctly.
    @TestCase
    func testParseEscapesAndUnicode(): Unit {
        @Assert(ss(parseJson("\"a\\nb\\t\\\"c\"")) == "a\nb\t\"c")
        // 中 is "中".
        @Assert(ss(parseJson("\"\\u4e2d\"")) == "中")
        // Surrogate pair 😀 is "😀".
        @Assert(ss(parseJson("\"\\uD83D\\uDE00\"")) == "😀")
    }

    // Serialization escapes mandatory characters and preserves UTF-8.
    @TestCase
    func testSerializeEscaping(): Unit {
        @Assert(JsonString("a\"b\\c\nd").toJsonString() == "\"a\\\"b\\\\c\\nd\"")
        @Assert(JsonString("中").toJsonString() == "\"中\"")
    }

    // The object builder keeps insertion order, so output is deterministic.
    @TestCase
    func testBuilderOrdered(): Unit {
        let obj = JsonObj().put("id", 42).put("name", "alice").put("active", true)
        @Assert(obj.toJsonString() == "{\"id\":42,\"name\":\"alice\",\"active\":true}")
    }

    // Parse -> serialize round-trips a document.
    @TestCase
    func testRoundTrip(): Unit {
        let src = "{\"a\":[1,2,3],\"b\":{\"c\":\"x\"}}"
        @Assert(parseJson(src).toJsonString() == src)
    }

    // Malformed input raises JsonException.
    @TestCase
    func testMalformedThrows(): Unit {
        var threw = false
        try {
            parseJson("{bad}")
        } catch (_: JsonException) {
            threw = true
        }
        @Assert(threw)
    }

    // res.json(JsonValue) sets the JSON content type and serialized body.
    @TestCase
    func testResJsonValue(): Unit {
        let res = HttpResponse()
        res.json(JsonObj().put("ok", true).build())
        @Assert(res.finished)
        @Assert(res.body == "{\"ok\":true}")
        let ct = match (res.headers.get("Content-Type")) { case Some(v) => v; case None => "" }
        @Expect(ct.contains("application/json"))
    }

    // jsonParser parses the body so a handler can read req.json().
    @TestCase
    func testJsonParserPopulatesReq(): Unit {
        let app = wen()
        app.use(jsonParser())
        app.post("/u", { req: HttpRequest, res: HttpResponse =>
            let name = match (req.json()) {
                case Some(j) => match (j.get("name")) {
                    case Some(v) => v.asString() ?? "?"
                    case None => "?"
                }
                case None => "?"
            }
            res.send(name)
        })
        let req = HttpRequest("POST", "/u"); req.path = "/u"
        req.headers["content-type"] = "application/json"
        req.body = "{\"name\":\"bob\"}"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body == "bob")
    }

    // A malformed JSON body leaves req.json() as None (request still proceeds).
    @TestCase
    func testJsonParserMalformedIsNone(): Unit {
        let app = wen()
        app.use(jsonParser())
        app.post("/u", { req: HttpRequest, res: HttpResponse =>
            let ok = match (req.json()) { case Some(_) => "yes"; case None => "no" }
            res.send(ok)
        })
        let req = HttpRequest("POST", "/u"); req.path = "/u"
        req.headers["content-type"] = "application/json"
        req.body = "{not json"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body == "no")
    }
}
