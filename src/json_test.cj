package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonTest {
    // ---- 一组小型取值辅助函数：把 JsonValue 中的值取出为具体类型，
    //      内部用 match 显式处理 Some/None，避免依赖 Option 的组合子，
    //      这样断言里能直接拿到裸值，读起来更直观。 -----
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

    // 验证各类标量（整数、布尔、null、字符串）都能被 parseJson 解析成对应的 JSON 类型，
    // 并且能用配套的访问器正确取回原值：
    // 整数 "42"/"-7" 经 asInt 取出应等于 42/-7；"true"/"false" 经 asBool 取出应为真/假
    //（?? 提供取不到时的兜底默认值）；"null" 应被 isNull 判定为真；
    // 带引号的 "\"hi\"" 经 asString 取出应为不含引号的字符串 hi。
    @TestCase
    func testParseScalars(): Unit {
        @Assert(si(parseJson("42")) == 42)
        @Assert(si(parseJson("-7")) == -7)
        @Assert(parseJson("true").asBool() ?? false)
        @Assert(!(parseJson("false").asBool() ?? true))
        @Assert(parseJson("null").isNull())
        @Assert(ss(parseJson("\"hi\"")) == "hi")
    }

    // 验证浮点字面量能被正确保留并以 Float64 读回：解析 "3.14" 后用 asFloat 取值，
    // 由于浮点存在精度误差，不能直接判等，而是断言其落在 (3.13, 3.15) 这个区间内。
    // 取不到浮点值（None 分支）则判定失败。
    @TestCase
    func testParseFloat(): Unit {
        match (parseJson("3.14").asFloat()) {
            case Some(f) => @Assert(f > 3.13 && f < 3.15)
            case None => @Assert(false)
        }
    }

    // 验证嵌套结构的导航：用 get(键) 进入对象字段、用 at(下标) 进入数组元素。
    // 解析后逐层取值断言：user.name 应为 "alice"，user.age 应为 30，
    // tags 数组下标 1 处的元素应为 "b"，且 tags 数组的长度（size）应为 2。
    @TestCase
    func testParseNested(): Unit {
        let v = parseJson("{\"user\":{\"name\":\"alice\",\"age\":30},\"tags\":[\"a\",\"b\"]}")
        @Assert(ss(field(field(v, "user"), "name")) == "alice")
        @Assert(si(field(field(v, "user"), "age")) == 30)
        @Assert(ss(elem(field(v, "tags"), 1)) == "b")
        @Assert(field(v, "tags").size() == 2)
    }

    // 验证字符串中的转义序列以及多字节 \u 转义都能被正确解码：
    // 字符串中的 \n、\t、\" 等转义应被还原成真正的换行、制表符、双引号字符。
    @TestCase
    func testParseEscapesAndUnicode(): Unit {
        @Assert(ss(parseJson("\"a\\nb\\t\\\"c\"")) == "a\nb\t\"c")
        // 中 是基本多文种平面内的码点，应解码为汉字“中”。
        @Assert(ss(parseJson("\"\\u4e2d\"")) == "中")
        // 😀 是一对代理项（surrogate pair），应组合成 emoji“😀”。
        @Assert(ss(parseJson("\"\\uD83D\\uDE00\"")) == "😀")
    }

    // 验证序列化时的转义规则：toJsonString 必须对 JSON 规范要求的字符进行转义
    //（如双引号 " 转为 \"、反斜杠 \ 转为 \\、换行转为 \n），
    // 同时对非 ASCII 的 UTF-8 字符（如“中”）保持原样输出而不做转义。
    @TestCase
    func testSerializeEscaping(): Unit {
        @Assert(JsonString("a\"b\\c\nd").toJsonString() == "\"a\\\"b\\\\c\\nd\"")
        @Assert(JsonString("中").toJsonString() == "\"中\"")
    }

    // 验证对象构造器（JsonObj + put 链式调用）保持字段的插入顺序，
    // 因而序列化输出是确定可预测的：按 id、name、active 的插入次序，
    // 结果字符串中的字段顺序也应与之一致。
    @TestCase
    func testBuilderOrdered(): Unit {
        let obj = JsonObj().put("id", 42).put("name", "alice").put("active", true)
        @Assert(obj.toJsonString() == "{\"id\":42,\"name\":\"alice\",\"active\":true}")
    }

    // 验证“解析再序列化”的往返一致性：把一段紧凑的 JSON 文本解析成对象、
    // 再用 toJsonString 序列化回字符串，结果应与原始输入逐字符相等
    //（说明解析与序列化互为逆操作，且不丢失结构与顺序）。
    @TestCase
    func testRoundTrip(): Unit {
        let src = "{\"a\":[1,2,3],\"b\":{\"c\":\"x\"}}"
        @Assert(parseJson(src).toJsonString() == src)
    }

    // 验证非法输入会抛出 JsonException：解析格式错误的文本 "{bad}"（键未加引号）时
    // 应当抛异常，通过 catch 捕获 JsonException 把标志位置真，最后断言确实抛过异常。
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

    // 验证 res.json(JsonValue) 的行为：传入一个构造好的 JSON 值时，
    // 它应把响应标记为已完成（finished），把响应体设置为该值的序列化结果，
    // 并把 Content-Type 头设置为 application/json。
    @TestCase
    func testResJsonValue(): Unit {
        let res = HttpResponse()
        res.json(JsonObj().put("ok", true).build())
        @Assert(res.finished)
        @Assert(res.body == "{\"ok\":true}")
        let ct = match (res.headers.get("Content-Type")) { case Some(v) => v; case None => "" }
        @Expect(ct.contains("application/json"))
    }

    // 验证 jsonParser 中间件会解析请求体，从而让后续处理器能通过 req.json() 读到结构化数据：
    // 注册 jsonParser 后，POST /u 的处理器从解析结果中取出字段 name 并回写到响应体。
    // 构造一个 Content-Type 为 application/json、请求体为 {"name":"bob"} 的请求，
    // 期望处理器最终把 "bob" 作为响应体返回。
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

    // 验证当请求体是非法 JSON 时，jsonParser 不会让请求失败，而是把 req.json() 留为 None，
    // 请求照常继续处理：处理器据此判断 req.json() 为 None 时返回 "no"。
    // 这里发送 Content-Type 为 application/json、但请求体为残缺的 "{not json"，
    // 期望响应体为 "no"（即解析失败被静默吞掉，未抛错也未中断流程）。
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
