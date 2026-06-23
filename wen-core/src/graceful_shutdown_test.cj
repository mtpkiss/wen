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
        // 检测 listen 协程是否意外抛出异常。早先这里是裸 try/catch 吞掉所有 Exception,
        // 结果 drainGate=Semaphore(0).release() 触发的 IllegalArgumentException 被悄悄吞了
        // 多个版本,demo 跑到 close 路径就崩。改成把异常标志上来,主线程断言它必须为 false。
        // (异常对象本体打印到 stdout 便于回归排查;AtomicBool 提供线程可见性,不需要 AtomicReference。)
        let listenDone = AtomicBool(false)
        let listenThrew = AtomicBool(false)
        spawn {
            try {
                app.listen(port)
            } catch (ex: Exception) {
                listenThrew.store(true)
                println("listen threw: ${ex}")
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
        @Assert(!listenThrew.load())
    }
}
