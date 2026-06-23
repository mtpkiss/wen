package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ExtrasTest {
    func hv(res: HttpResponse, name: String): String {
        match (res.get(name)) {
            case Some(v) => return v;
            case None => return ""
        }
    }

    // res.vary 追加且去重。
    @TestCase
    func testVary(): Unit {
        let res = HttpResponse()
        res.vary("Accept")
        res.vary("Accept-Encoding")
        res.vary("accept") // 大小写不敏感,不重复
        @Assert(hv(res, "Vary") == "Accept, Accept-Encoding")
    }

    // redirect 带状态码。
    @TestCase
    func testRedirectStatus(): Unit {
        let res = HttpResponse()
        res.redirect(301, "/new")
        @Assert(res.statusCode == 301)
        @Assert(hv(res, "Location") == "/new")
    }

    // app.enable/disable/enabled/disabled。
    @TestCase
    func testEnableDisable(): Unit {
        let app = wen()
        app.enable("trust proxy")
        @Assert(app.enabled("trust proxy"))
        @Assert(!app.disabled("trust proxy"))
        app.disable("trust proxy")
        @Assert(!app.enabled("trust proxy"))
        @Assert(app.disabled("trust proxy"))
        // 未设置的键视为未启用。
        @Assert(!app.enabled("never set"))
        @Assert(app.disabled("never set"))
    }
}
