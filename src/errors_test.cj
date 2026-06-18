package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试 HttpException -> 状态码的默认映射:直接抛带状态码、子类语义化异常、普通异常
 * 仍 500,以及错误处理中间件优先于默认兜底。
 */

// 测试用:语义化的 404 异常(继承 HttpException)。
class ResourceNotFound <: HttpException {
    init() {
        super(404, "Not Found")
    }
}

@Test
class HttpExceptionTest {
    // 直接抛 HttpException(status, message):框架据 status 回状态码、以 message 作响应体。
    @TestCase
    func testStatusAndMessageMapped(): Unit {
        let app = wen()
        app.get("/x", {
            _: HttpRequest, _: HttpResponse => throw HttpException(422, "bad email")
        })
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 422)
        @Assert(res.body == "bad email")
    }

    // 继承 HttpException 的语义化异常同样被映射。
    @TestCase
    func testSubclassMapped(): Unit {
        let app = wen()
        app.get("/nf", {
            _: HttpRequest, _: HttpResponse => throw ResourceNotFound()
        })
        let req = HttpRequest("GET", "/nf")
        req.path = "/nf"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 404)
        @Assert(res.body == "Not Found")
    }

    // 非 HttpException 的普通异常仍兜底为 500。
    @TestCase
    func testPlainExceptionStill500(): Unit {
        let app = wen()
        app.get("/boom", {
            _: HttpRequest, _: HttpResponse => throw Exception("oops")
        })
        let req = HttpRequest("GET", "/boom")
        req.path = "/boom"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 500)
        @Assert(res.body == "Internal Server Error")
    }

    // 错误处理中间件优先于默认兜底:注册后由它接管,默认 status 映射不再触发。
    @TestCase
    func testErrorHandlerOverrides(): Unit {
        let app = wen()
        app.get("/x", {
            _: HttpRequest, _: HttpResponse => throw HttpException(422, "x")
        })
        app.use({
            _: Exception, _: HttpRequest, res: HttpResponse, _: Next => res.status(418).send("handled")
        })
        let req = HttpRequest("GET", "/x")
        req.path = "/x"
        let res = HttpResponse()
        app.handle(req, res)
        @Assert(res.statusCode == 418)
        @Assert(res.body == "handled")
    }
}
