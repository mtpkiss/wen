package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class SessionTest {
    func cookieHeader(res: HttpResponse): String {
        if (res.setCookies.size == 0) {
            return ""
        }
        return res.setCookies[0]
    }

    // 取响应里 Set-Cookie 中 sid 的值(含签名),供下一请求回送。
    func sidFrom(res: HttpResponse): String {
        // 形如 "sid=<value>.<sig>; Path=/; HttpOnly"
        let c = cookieHeader(res)
        let (kv, _) = splitOnce(c, ";")
        let (_, v) = splitOnce(kv, "=")
        return v
    }

    // 签名 Cookie:写入后能被 signedCookie 验签取回;密钥不同则验签失败。
    @TestCase
    func testSignedCookieRoundTrip(): Unit {
        let app = wen()
        app.cookieSecret = "s3cr3t"
        app.use(cookieParser())
        app.get("/set", {
            _: HttpRequest, res: HttpResponse => res.cookie("token", "abc123", signed: true).send("ok")
        })
        app.get(
            "/get",
            {
                req: HttpRequest, res: HttpResponse =>
                    let v = match (req.signedCookie("token")) {
                        case Some(x) => x;
                        case None => "INVALID"
                    }
                    res.send(v)
            }
        )

        let r1 = HttpRequest("GET", "/set");
        r1.path = "/set"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        let signed = sidFrom(s1) // "abc123.<sig>"
        @Expect(signed.contains("abc123."))

        // 回送该签名 Cookie -> 验签通过,取回原值。
        let r2 = HttpRequest("GET", "/get");
        r2.path = "/get"
        r2.headers["cookie"] = "token=${signed}"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.body == "abc123")
    }

    // 篡改签名 Cookie 的值后,验签应失败(返回 None)。
    @TestCase
    func testTamperedCookieRejected(): Unit {
        let app = wen()
        app.cookieSecret = "s3cr3t"
        app.use(cookieParser())
        app.get(
            "/get",
            {
                req: HttpRequest, res: HttpResponse =>
                    let v = match (req.signedCookie("token")) {
                        case Some(x) => x;
                        case None => "INVALID"
                    }
                    res.send(v)
            }
        )
        let r = HttpRequest("GET", "/get");
        r.path = "/get"
        // 值被改成 evil,但签名仍是旧的 -> 不匹配。
        r.headers["cookie"] = "token=evil.0000000000000000000000000000000000000000000000000000000000000000"
        let res = HttpResponse();
        app.handle(r, res)
        @Assert(res.body == "INVALID")
    }

    // session:首个请求新建会话并下发签名 sid;带回该 sid 的后续请求能读到之前写入的数据。
    @TestCase
    func testSessionPersistsAcrossRequests(): Unit {
        let app = wen()
        app.cookieSecret = "sess-key"
        let store = MemorySessionStore()
        app.use(cookieParser())
        app.use(session(store))
        app.get(
            "/login",
            {
                req: HttpRequest, res: HttpResponse =>
                    match (req.session) {
                        case Some(s) => s.set("user", "alice")
                        case None => ()
                    }
                    res.send("logged-in")
            }
        )
        app.get(
            "/who",
            {
                req: HttpRequest, res: HttpResponse =>
                    let u = match (req.session) {
                        case Some(s) => match (s.get("user")) {
                            case Some(v) => v;
                            case None => "anon"
                        }
                        case None => "no-session"
                    }
                    res.send(u)
            }
        )

        // 1) 登录:写会话,响应应带 Set-Cookie(签名 sid)。
        let r1 = HttpRequest("GET", "/login");
        r1.path = "/login"
        let s1 = HttpResponse();
        app.handle(r1, s1)
        @Assert(s1.setCookies.size == 1)
        let sid = sidFrom(s1)
        @Expect(!sid.isEmpty())

        // 2) 带 sid 再访问:应读到上一步写入的 user=alice。
        let r2 = HttpRequest("GET", "/who");
        r2.path = "/who"
        r2.headers["cookie"] = "sid=${sid}"
        let s2 = HttpResponse();
        app.handle(r2, s2)
        @Assert(s2.body == "alice")

        // 既有会话不再重复下发 Set-Cookie。
        @Assert(s2.setCookies.size == 0)
    }

    // 没带 sid 的请求拿到的是全新空会话。
    @TestCase
    func testFreshSessionWhenNoCookie(): Unit {
        let app = wen()
        app.cookieSecret = "k"
        app.use(cookieParser())
        app.use(session())
        app.get(
            "/who",
            {
                req: HttpRequest, res: HttpResponse =>
                    let u = match (req.session) {
                        case Some(s) => match (s.get("user")) {
                            case Some(v) => v;
                            case None => "anon"
                        }
                        case None => "no-session"
                    }
                    res.send(u)
            }
        )
        let r = HttpRequest("GET", "/who");
        r.path = "/who"
        let res = HttpResponse();
        app.handle(r, res)
        @Assert(res.body == "anon")
        @Assert(res.setCookies.size == 1) // 新会话下发 sid
    }
}
