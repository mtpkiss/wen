package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试 req.signedCookies():把所有验签通过的 Cookie 汇总成一张 name -> 已验签值 的映射。
 *
 * 已存在的 SessionTest 覆盖了 signedCookie(name) 的单值取用,本文件聚焦整表映射:
 * 验证哪些条目进入结果、哪些被剔除,以及无密钥 / 无 cookies 时的边界行为。
 */
@Test
class SignedCookiesMapTest {
    // 用给定密钥为 value 现算一个合法签名串,形如 "<value>.<sig>"。
    func sign(secret: String, value: String): String {
        return "${value}.${hmacSha256Hex(secret, value)}"
    }

    // 构造一个挂在 app 上的 req(让 signedCookies 能读到 cookieSecret)。
    func reqOn(app: Application, cookies: HashMap<String, String>): HttpRequest {
        let req = HttpRequest("GET", "/x")
        req.app = Some(app)
        for ((k, v) in cookies) {
            req.cookies[k] = v
        }
        return req
    }

    // 全部都是合法签名 -> 全部进入结果,值为原文。
    @TestCase
    func testAllVerifiedAppear(): Unit {
        let app = wen()
        app.cookieSecret = "k"
        let bag = HashMap<String, String>()
        bag["a"] = sign("k", "hello")
        bag["b"] = sign("k", "world")
        let m = reqOn(app, bag).signedCookies()
        @Assert(m.size == 2)
        @Assert(m["a"] == "hello")
        @Assert(m["b"] == "world")
    }

    // 篡改的 / 形态不对的条目不进入结果。
    @TestCase
    func testTamperedAndPlainSkipped(): Unit {
        let app = wen()
        app.cookieSecret = "k"
        let bag = HashMap<String, String>()
        bag["good"] = sign("k", "ok")
        bag["bad"] = "tampered.0000000000000000000000000000000000000000000000000000000000000000"
        bag["plain"] = "no-dot-no-sig" // 形态不对(无 "."),验签失败
        let m = reqOn(app, bag).signedCookies()
        @Assert(m.size == 1)
        @Assert(m["good"] == "ok")
        @Assert(!m.contains("bad"))
        @Assert(!m.contains("plain"))
    }

    // 用错误密钥签的 Cookie 不进入结果。
    @TestCase
    func testWrongSecretRejected(): Unit {
        let app = wen()
        app.cookieSecret = "real"
        let bag = HashMap<String, String>()
        bag["a"] = sign("attacker", "evil")
        let m = reqOn(app, bag).signedCookies()
        @Assert(m.size == 0)
    }

    // 未设置 cookieSecret -> 返回空表(而非抛异常)。
    @TestCase
    func testNoSecretReturnsEmpty(): Unit {
        let app = wen()
        // 不设 cookieSecret
        let bag = HashMap<String, String>()
        bag["a"] = "anything.signature"
        let m = reqOn(app, bag).signedCookies()
        @Assert(m.size == 0)
    }

    // 没有任何 Cookie -> 空表。
    @TestCase
    func testNoCookiesReturnsEmpty(): Unit {
        let app = wen()
        app.cookieSecret = "k"
        let bag = HashMap<String, String>()
        let m = reqOn(app, bag).signedCookies()
        @Assert(m.size == 0)
    }

    // 未绑定 app(req.app=None)-> 空表(无密钥可取)。
    @TestCase
    func testNoAppReturnsEmpty(): Unit {
        let req = HttpRequest("GET", "/x")
        req.cookies["a"] = "anything.signature"
        @Assert(req.signedCookies().size == 0)
    }

    // 值中含 "." 的合法签名能正确分割。
    @TestCase
    func testValueContainingDot(): Unit {
        let app = wen()
        app.cookieSecret = "k"
        let bag = HashMap<String, String>()
        bag["a"] = sign("k", "v1.2.3")
        let m = reqOn(app, bag).signedCookies()
        @Assert(m["a"] == "v1.2.3")
    }

    // signedCookies() 与 signedCookie(name) 对同一组数据结论一致。
    @TestCase
    func testConsistencyWithSingleGetter(): Unit {
        let app = wen()
        app.cookieSecret = "k"
        let bag = HashMap<String, String>()
        bag["good"] = sign("k", "y")
        bag["bad"] = "x.deadbeef"
        let req = reqOn(app, bag)
        let m = req.signedCookies()
        match (req.signedCookie("good")) {
            case Some(v) => @Assert(m["good"] == v)
            case None => @Assert(false)
        }
        match (req.signedCookie("bad")) {
            case Some(_) => @Assert(false)
            case None => @Assert(!m.contains("bad"))
        }
    }

    // 签名 cookie 的值含字面 "+" 字符:写入端原样写出,而读取端会对整段 cookie 值
    // 做 urlDecode 把 "+" 当空格。两端不对称会让重算的 HMAC 与签名段对不上,签名
    // 验证错误地失败。这里直接用未编码的 "a+b" 拼出合法签名,断言 signedCookie
    // 仍能取回原值,确认读写两端对编码的处理一致。
    @TestCase
    func testSignedCookieWithPlusChar(): Unit {
        let app = wen()
        app.cookieSecret = "the-secret"
        let value = "a+b"
        let signed = "${value}.${hmacSha256Hex(app.cookieSecret, value)}"
        let req = HttpRequest("GET", "/")
        req.app = Some(app)
        req.headers["cookie"] = "x=${signed}"
        match (req.signedCookie("x")) {
            case Some(v) => @Assert(v == "a+b")
            case None => @Assert(false)
        }
    }

    // 同上,验证 cookie 值含字面 "%" 字符也能正确还原。"%" 是 percent-encoding 的
    // 转义引子,稍不留意就会被读取端误当作编码序列再次解码。用 "raw%20literal" 这
    // 种"看起来像编码的明文"做反例,断言写读链路保留原始字节。
    @TestCase
    func testSignedCookieWithPercentLiteral(): Unit {
        let app = wen()
        app.cookieSecret = "the-secret"
        let value = "raw%20literal"
        let signed = "${value}.${hmacSha256Hex(app.cookieSecret, value)}"
        let req = HttpRequest("GET", "/")
        req.app = Some(app)
        req.headers["cookie"] = "x=${signed}"
        match (req.signedCookie("x")) {
            case Some(v) => @Assert(v == "raw%20literal")
            case None => @Assert(false)
        }
    }
}
