package wen

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// A sample object that middleware might attach to a request (e.g. an
// authenticated user), used to exercise req.locals.
class StashedUser {
    let name: String
    init(name: String) {
        this.name = name
    }
}

@Test
class AppTest {
    // A simple GET "/" handler returns body "hi" with status 200.
    @TestCase
    func testBasicGet(): Unit {
        let app = wen()
        app.get("/", { req: HttpRequest, res: HttpResponse =>
            res.send("hi")
        })
        let req = HttpRequest("GET", "/")
        req.path = "/"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "hi")
    }

    // A :param route captures id and echoes it back in JSON.
    @TestCase
    func testParamRoute(): Unit {
        let app = wen()
        app.get("/users/:id", { req: HttpRequest, res: HttpResponse =>
            // Unwrap ?String with a match rather than relying on ?? on Option.
            var id = "?"
            match (req.param("id")) {
                case Some(v) => id = v
                case None => ()
            }
            res.json("{\"id\":\"${id}\"}")
        })
        let req = HttpRequest("GET", "/users/42")
        req.path = "/users/42"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        // Body should contain the captured id "42".
        @Expect(res.body.contains("42"))
    }

    // An unmatched route yields a 404.
    @TestCase
    func testUnmatchedRouteIs404(): Unit {
        let app = wen()
        app.get("/", { req: HttpRequest, res: HttpResponse =>
            res.send("hi")
        })
        let req = HttpRequest("GET", "/nope")
        req.path = "/nope"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // parseInt stops at the first non-digit and ignores trailing junk.
    @TestCase
    func testParseInt(): Unit {
        @Assert(parseInt("123abc") == 123)
    }

    // urlDecode handles percent-encoding and '+'.
    @TestCase
    func testUrlDecode(): Unit {
        @Assert(urlDecode("a%20b+c"), "a b c")
    }

    // splitOnce splits at the first separator occurrence.
    @TestCase
    func testSplitOnce(): Unit {
        let (a, b) = splitOnce("k:v", ":")
        @Assert(a, "k")
        @Assert(b, "v")
    }

    // A mounted middleware sees the request path with its mount prefix removed.
    @TestCase
    func testMountStripsPrefix(): Unit {
        let app = wen()
        app.use("/static", { req: HttpRequest, res: HttpResponse, _: Next =>
            res.send(req.path)
        })
        let req = HttpRequest("GET", "/static/css/app.css")
        req.path = "/static/css/app.css"
        let res = HttpResponse()
        app.handle(req, res)
        // Prefix "/static" stripped to the remainder.
        @Assert(res.body, "/css/app.css")
    }

    // app.route(path) binds multiple verbs to one path; each dispatches correctly.
    @TestCase
    func testRouteChaining(): Unit {
        let app = wen()
        app.route("/book")
           .get({ req: HttpRequest, res: HttpResponse => res.send("list") })
           .post({ req: HttpRequest, res: HttpResponse => res.send("create") })

        let getReq = HttpRequest("GET", "/book")
        getReq.path = "/book"
        let getRes = HttpResponse()
        app.handle(getReq, getRes)
        @Assert(getRes.statusCode == 200)
        @Assert(getRes.body, "list")

        let postReq = HttpRequest("POST", "/book")
        postReq.path = "/book"
        let postRes = HttpResponse()
        app.handle(postReq, postRes)
        @Assert(postRes.statusCode == 200)
        @Assert(postRes.body, "create")
    }

    // Middleware can stash a typed object on req.locals and a downstream
    // handler can read it back and downcast it.
    @TestCase
    func testReqLocalsTyped(): Unit {
        let app = wen()
        app.use({ req: HttpRequest, _: HttpResponse, next: Next =>
            req.setLocal("user", StashedUser("alice"))
            next()
        })
        app.get("/", { req: HttpRequest, res: HttpResponse =>
            var name = "?"
            match (req.local("user")) {
                case Some(v) => match (v as StashedUser) {
                    case Some(u) => name = u.name
                    case None => ()
                }
                case None => ()
            }
            res.send(name)
        })
        let req = HttpRequest("GET", "/"); req.path = "/"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body, "alice")
    }

    // res.sendBytes sets a raw binary body that serialization will use verbatim.
    @TestCase
    func testResSendBytes(): Unit {
        let res = HttpResponse()
        res.contentType("application/octet-stream").sendBytes([UInt8(1), UInt8(2), UInt8(3)])
        @Assert(res.finished)
        match (res.bodyBytes) {
            case Some(b) => @Assert(b.size == 3)
            case None => @Assert(false)
        }
    }

    // req.bodyBytes defaults to empty when constructed directly.
    @TestCase
    func testReqBodyBytesDefault(): Unit {
        let req = HttpRequest("GET", "/")
        @Assert(req.bodyBytes.size == 0)
    }

    // A constrained param :id(\d+) matches only numeric segments.
    @TestCase
    func testParamConstraintMatches(): Unit {
        let app = wen()
        app.get("/users/:id(\\d+)", { req: HttpRequest, res: HttpResponse =>
            let id = match (req.param("id")) { case Some(v) => v; case None => "?" }
            res.send(id)
        })
        let ok = HttpRequest("GET", "/users/42"); ok.path = "/users/42"
        let okRes = HttpResponse(); app.handle(ok, okRes)
        @Assert(okRes.statusCode == 200)
        @Assert(okRes.body, "42")

        // Non-numeric id does not match the constrained route -> 404.
        let bad = HttpRequest("GET", "/users/abc"); bad.path = "/users/abc"
        let badRes = HttpResponse(); app.handle(bad, badRes)
        @Assert(badRes.statusCode == 404)
    }

    // A constrained route and an unconstrained fallback can coexist.
    @TestCase
    func testParamConstraintFallthrough(): Unit {
        let app = wen()
        app.get("/p/:n(\\d+)", { _: HttpRequest, res: HttpResponse => res.send("num") })
        app.get("/p/:n", { _: HttpRequest, res: HttpResponse => res.send("any") })

        let r1 = HttpRequest("GET", "/p/7"); r1.path = "/p/7"
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Assert(s1.body, "num")

        let r2 = HttpRequest("GET", "/p/hello"); r2.path = "/p/hello"
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Assert(s2.body, "any")
    }

    // res.set accepts a map to apply several headers at once.
    @TestCase
    func testResSetBatch(): Unit {
        let res = HttpResponse()
        let h = HashMap<String, String>()
        h["X-A"] = "1"
        h["X-B"] = "2"
        res.set(h)
        let a = match (res.headers.get("X-A")) { case Some(v) => v; case None => "" }
        let b = match (res.headers.get("X-B")) { case Some(v) => v; case None => "" }
        @Assert(a, "1")
        @Assert(b, "2")
    }

    // A known path with the wrong method yields 405 + Allow header.
    @TestCase
    func testMethodNotAllowed(): Unit {
        let app = wen()
        app.get("/x", { _: HttpRequest, res: HttpResponse => res.send("ok") })
        app.post("/x", { _: HttpRequest, res: HttpResponse => res.send("made") })
        let req = HttpRequest("PUT", "/x"); req.path = "/x"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 405)
        let allow = match (res.get("Allow")) { case Some(v) => v; case None => "" }
        @Expect(allow.contains("GET"))
        @Expect(allow.contains("POST"))
    }

    // An OPTIONS request to a known path is auto-answered with 204 + Allow.
    @TestCase
    func testAutoOptions(): Unit {
        let app = wen()
        app.get("/x", { _: HttpRequest, res: HttpResponse => res.send("ok") })
        let req = HttpRequest("OPTIONS", "/x"); req.path = "/x"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 204)
        let allow = match (res.get("Allow")) { case Some(v) => v; case None => "" }
        @Expect(allow.contains("GET"))
        @Expect(allow.contains("OPTIONS"))
        @Expect(allow.contains("HEAD"))
    }

    // A HEAD request with no HEAD route falls back to GET, headers only.
    @TestCase
    func testAutoHead(): Unit {
        let app = wen()
        app.get("/x", { _: HttpRequest, res: HttpResponse => res.send("hello") })
        let req = HttpRequest("HEAD", "/x"); req.path = "/x"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "")
        let len = match (res.get("Content-Length")) { case Some(v) => v; case None => "" }
        @Assert(len, "5")
    }

    // A truly unknown path still yields 404.
    @TestCase
    func testUnknownPathStill404(): Unit {
        let app = wen()
        app.get("/x", { _: HttpRequest, res: HttpResponse => res.send("ok") })
        let req = HttpRequest("GET", "/nope"); req.path = "/nope"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // A path param is URL-decoded when captured.
    @TestCase
    func testParamUrlDecoded(): Unit {
        let app = wen()
        app.get("/u/:name", { req: HttpRequest, res: HttpResponse =>
            let n = match (req.param("name")) { case Some(v) => v; case None => "?" }
            res.send(n)
        })
        let req = HttpRequest("GET", "/u/john%20doe"); req.path = "/u/john%20doe"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body, "john doe")
    }

    // req.app is set during dispatch, so middleware can read app settings.
    @TestCase
    func testReqApp(): Unit {
        let app = wen()
        app.set("title", "wen")
        app.get("/", { req: HttpRequest, res: HttpResponse =>
            let t = match (req.setting("title")) { case Some(v) => v; case None => "?" }
            res.send(t)
        })
        let req = HttpRequest("GET", "/"); req.path = "/"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body, "wen")
    }

    // res.get reads back a header set on the response.
    @TestCase
    func testResGet(): Unit {
        let res = HttpResponse()
        res.set("X-Trace", "abc")
        let v = match (res.get("X-Trace")) { case Some(x) => x; case None => "" }
        @Assert(v, "abc")
    }

    // res.locals / app.locals hold typed values.
    @TestCase
    func testLocalsStores(): Unit {
        let app = wen()
        app.setLocal("svc", StashedUser("service"))
        let res = HttpResponse()
        res.locals["k"] = StashedUser("scoped")
        var a = "?"
        match (app.local("svc")) {
            case Some(v) => match (v as StashedUser) { case Some(u) => a = u.name; case None => () }
            case None => ()
        }
        @Assert(a, "service")
        @Assert(res.locals.size == 1)
    }

    // res.stream marks the response hijacked and, without a live socket,
    // accumulates chunks into res.body so they can be asserted.
    @TestCase
    func testStreamFallback(): Unit {
        let app = wen()
        app.get("/s", { _: HttpRequest, res: HttpResponse =>
            res.stream({ w: StreamWriter =>
                w.write("a")
                w.write("b")
            })
        })
        let req = HttpRequest("GET", "/s"); req.path = "/s"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.hijacked)
        @Assert(res.finished)
        @Assert(res.body, "ab")
    }

    // res.sse formats SSE frames; the test-mode writer captures them in res.body.
    @TestCase
    func testSseFrames(): Unit {
        let app = wen()
        app.get("/events", { _: HttpRequest, res: HttpResponse =>
            res.sse({ s: SseWriter =>
                s.send("hello")
                s.event("tick", "1")
            })
        })
        let req = HttpRequest("GET", "/events"); req.path = "/events"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.hijacked)
        let ct = match (res.headers.get("Content-Type")) { case Some(v) => v; case None => "" }
        @Expect(ct.contains("text/event-stream"))
        // Default event: "data: hello\n\n"; named: "event: tick\n" + "data: 1\n\n".
        @Expect(res.body.contains("data: hello\n\n"))
        @Expect(res.body.contains("event: tick\n"))
        @Expect(res.body.contains("data: 1\n\n"))
    }

    // req.hostname reads the Host header and strips the port.
    @TestCase
    func testHostname(): Unit {
        let req = HttpRequest("GET", "/")
        req.headers["host"] = "example.com:8080"
        let h = match (req.hostname()) { case Some(v) => v; case None => "?" }
        @Assert(h, "example.com")
    }

    // req.ip defaults to empty when handled without a socket (e.g. app.handle).
    @TestCase
    func testReqIpDefault(): Unit {
        let req = HttpRequest("GET", "/")
        @Assert(req.ip, "")
    }

    // cookieParser populates req.cookies from the Cookie header.
    @TestCase
    func testCookieParser(): Unit {
        let app = wen()
        app.use(cookieParser())
        app.get("/", { req: HttpRequest, res: HttpResponse =>
            let sid = match (req.cookie("sid")) { case Some(v) => v; case None => "?" }
            res.send(sid)
        })
        let req = HttpRequest("GET", "/"); req.path = "/"
        req.headers["cookie"] = "sid=abc123; theme=dark"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.body, "abc123")
    }

    // res.cookie queues a Set-Cookie entry with the chosen attributes.
    @TestCase
    func testResCookie(): Unit {
        let res = HttpResponse()
        res.cookie("sid", "xyz", httpOnly: true, maxAge: 3600)
        @Assert(res.setCookies.size == 1)
        @Expect(res.setCookies[0].contains("sid=xyz"))
        @Expect(res.setCookies[0].contains("HttpOnly"))
        @Expect(res.setCookies[0].contains("Max-Age=3600"))
    }

    // clearCookie expires the cookie via Max-Age=0.
    @TestCase
    func testClearCookie(): Unit {
        let res = HttpResponse()
        res.clearCookie("sid")
        @Assert(res.setCookies.size == 1)
        @Expect(res.setCookies[0].contains("Max-Age=0"))
    }

    // req.isType matches the body Content-Type by shorthand.
    @TestCase
    func testReqIsType(): Unit {
        let req = HttpRequest("POST", "/")
        req.headers["content-type"] = "application/json; charset=utf-8"
        @Assert(req.isType("json"))
        @Assert(!req.isType("html"))
    }

    // req.accepts honours the Accept header and wildcards.
    @TestCase
    func testReqAccepts(): Unit {
        let req = HttpRequest("GET", "/")
        req.headers["accept"] = "text/html,application/json"
        @Assert(req.accepts("json"))
        @Assert(req.accepts("html"))
        @Assert(!req.accepts("css"))
    }

    // res.mimeType expands a shorthand into a full Content-Type.
    @TestCase
    func testResMimeType(): Unit {
        let res = HttpResponse()
        res.mimeType("json")
        let ct = match (res.headers.get("Content-Type")) { case Some(v) => v; case None => "" }
        @Expect(ct.contains("application/json"))
    }

    // res.append builds a multi-valued header.
    @TestCase
    func testResAppend(): Unit {
        let res = HttpResponse()
        res.append("Vary", "Accept")
        res.append("Vary", "Origin")
        let v = match (res.headers.get("Vary")) { case Some(x) => x; case None => "" }
        @Assert(v, "Accept, Origin")
    }

    // res.sendFile serves an existing file with a guessed Content-Type. Uses a
    // self-created temp file so the test does not depend on the working dir.
    @TestCase
    func testSendFile(): Unit {
        let path = "._cjx_sendfile_test.html"
        File.writeTo(path, "<h1>hi</h1>".toArray())
        let res = HttpResponse()
        res.sendFile(path)
        @Assert(res.finished)
        let ct = match (res.headers.get("Content-Type")) { case Some(v) => v; case None => "" }
        @Expect(ct.contains("text/html"))
        remove(path)
    }

    // res.sendFile on a missing file throws, feeding the error pipeline.
    @TestCase
    func testSendFileMissingThrows(): Unit {
        let app = wen()
        app.get("/f", { _: HttpRequest, res: HttpResponse => res.sendFile("public/nope.xyz") })
        app.use({ _: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
            res.status(404).send("no file")
        })
        let req = HttpRequest("GET", "/f"); req.path = "/f"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 404)
        @Assert(res.body, "no file")
    }

    // A thrown error is routed to a registered error handler, which renders it.
    @TestCase
    func testErrorHandlerCatches(): Unit {
        let app = wen()
        app.get("/boom", { _: HttpRequest, _: HttpResponse =>
            throw Exception("kaboom")
        })
        app.use({ e: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
            res.status(500).json("{\"error\":\"${e.message}\"}")
        })
        let req = HttpRequest("GET", "/boom"); req.path = "/boom"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 500)
        @Expect(res.body.contains("kaboom"))
    }

    // Without any error handler, a thrown error becomes a default 500.
    @TestCase
    func testErrorDefault500(): Unit {
        let app = wen()
        app.get("/boom", { _: HttpRequest, _: HttpResponse =>
            throw Exception("kaboom")
        })
        let req = HttpRequest("GET", "/boom"); req.path = "/boom"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 500)
    }

    // Error handlers are skipped for ordinary successful requests.
    @TestCase
    func testErrorHandlerSkippedOnSuccess(): Unit {
        let app = wen()
        app.get("/ok", { _: HttpRequest, res: HttpResponse => res.send("fine") })
        app.use({ _: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
            res.status(500).send("should-not-run")
        })
        let req = HttpRequest("GET", "/ok"); req.path = "/ok"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "fine")
    }

    // An error thrown inside a mounted sub-router propagates to the parent's
    // error handler.
    @TestCase
    func testErrorFromMountedRouter(): Unit {
        let app = wen()
        let sub = Router()
        sub.get("/explode", { _: HttpRequest, _: HttpResponse => throw Exception("sub-fail") })
        app.use("/api", sub)
        app.use({ e: Exception, _: HttpRequest, res: HttpResponse, _: Next =>
            res.status(500).send(e.message)
        })
        let req = HttpRequest("GET", "/api/explode"); req.path = "/api/explode"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 500)
        @Assert(res.body, "sub-fail")
    }

    // A mounted sub-router (mini-app) handles /birds and /birds/about, and its
    // own router-level middleware runs for both.
    @TestCase
    func testMountedRouter(): Unit {
        let app = wen()
        let birds = Router()
        birds.use({ req: HttpRequest, _: HttpResponse, next: Next =>
            req.attributes["hit"] = "1"
            next()
        })
        birds.get("/", { req: HttpRequest, res: HttpResponse =>
            let hit = match (req.attribute("hit")) { case Some(v) => v; case None => "0" }
            res.send("home:${hit}")
        })
        birds.get("/about", { _: HttpRequest, res: HttpResponse => res.send("about") })
        app.use("/birds", birds)

        let r1 = HttpRequest("GET", "/birds"); r1.path = "/birds"
        let s1 = HttpResponse(); app.handle(r1, s1)
        @Assert(s1.statusCode == 200)
        @Assert(s1.body, "home:1")

        let r2 = HttpRequest("GET", "/birds/about"); r2.path = "/birds/about"
        let s2 = HttpResponse(); app.handle(r2, s2)
        @Assert(s2.statusCode == 200)
        @Assert(s2.body, "about")
    }

    // An unmatched path inside a mounted router falls through to a 404 rather
    // than being swallowed by the sub-router.
    @TestCase
    func testMountedRouterFallthrough(): Unit {
        let app = wen()
        let birds = Router()
        birds.get("/about", { _: HttpRequest, res: HttpResponse => res.send("about") })
        app.use("/birds", birds)

        let req = HttpRequest("GET", "/birds/missing"); req.path = "/birds/missing"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 404)
    }

    // A param in the mount path (/birds/:type) is visible to sub-routes
    // (mergeParams behaviour).
    @TestCase
    func testMountedRouterMergeParams(): Unit {
        let app = wen()
        let sub = Router()
        sub.get("/info", { req: HttpRequest, res: HttpResponse =>
            let t = match (req.param("type")) { case Some(v) => v; case None => "?" }
            res.send(t)
        })
        app.use("/birds/:type", sub)

        let req = HttpRequest("GET", "/birds/eagle/info"); req.path = "/birds/eagle/info"
        let res = HttpResponse(); app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body, "eagle")
    }

    // After a mounted middleware calls next(), downstream routes see the full path.
    @TestCase
    func testMountRestoresPathForDownstream(): Unit {
        let app = wen()
        app.use("/api", { _: HttpRequest, _: HttpResponse, next: Next => next() })
        app.get("/api/health", { req: HttpRequest, res: HttpResponse =>
            res.send(req.path)
        })
        let req = HttpRequest("GET", "/api/health")
        req.path = "/api/health"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        // The exact route still matched and saw the original, full path.
        @Assert(res.body, "/api/health")
    }
}
