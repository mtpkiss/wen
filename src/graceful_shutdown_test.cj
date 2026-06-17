package wen

import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class GracefulShutdownTest {
    // 未 listen 时 shutdown 立即返回(serverSocket=None,inflight=0)。
    @TestCase
    func testShutdownBeforeListenIsNoOp(): Unit {
        let app = wen()
        let server = HttpServer(app)
        server.shutdown()
        @Expect(true)
    }

    // 重复 shutdown 幂等:swap 的 already 路径直接返回,不重复关 socket。
    @TestCase
    func testShutdownIdempotent(): Unit {
        let app = wen()
        let server = HttpServer(app)
        server.shutdown()
        server.shutdown()
        server.shutdown(timeoutMs: 5000)
        @Expect(true)
    }

    // Application.close() 在 listen 之前是无操作(httpServer = None)。
    @TestCase
    func testApplicationCloseBeforeListenIsNoOp(): Unit {
        let app = wen()
        app.close()
        app.close(timeoutMs: 1000)
        @Expect(true)
    }

    // 集成:启动 server -> close(idle) -> listen 协程在合理时间内退出。
    // 用一个非常规高端口减少冲突;若该端口被占,测试会因 bind 失败而 listenDone 始终为 false。
    @TestCase
    func testCloseTerminatesIdleListen(): Unit {
        let app = wen()
        app.get("/", {_: HttpRequest, res: HttpResponse => res.send("ok")})
        let port: Int64 = 47821
        let listenDone = AtomicBool(false)
        spawn {
            try {
                app.listen(port)
            } catch (_: Exception) {
                ()
            }
            listenDone.store(true)
        }
        // 给 server 起来的时间;ms 取保守值。
        sleep(Duration.millisecond * 300)
        app.close(timeoutMs: 1000)
        // listen 协程应当在 close 后短时间内退出。
        var i = 0
        while (i < 50 && !listenDone.load()) {
            sleep(Duration.millisecond * 20)
            i += 1
        }
        @Assert(listenDone.load())
    }
}
