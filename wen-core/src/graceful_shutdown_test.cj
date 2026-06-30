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

    // listen → close → 再注册路由 → 再 listen 的完整循环必须可用。
    // Express 允许同一 app 实例被 close 后重新启动(测试常用、SIGHUP 热重载常用),
    // 但 wen 早先在 markFrozen 后永远不会复位 frozen,close 完成后再 app.get(...)
    // 会被 ensureNotFrozen 拦截抛 IllegalStateException,从用户视角看 app 实例
    // 被一次性消耗 — 不符合 Application 作为容器的语义,也容易在测试集里因为
    // 重用实例而踩坑。
    // 修法:Application.close 在 HttpServer.shutdown 返回后(此时所有 worker 已
    // 退出,无并发可见性问题)把 frozen 复位、router 联动 unfreeze、清掉
    // httpServer 引用,允许同实例再次 listen。
    @TestCase
    func testReRegisterAfterCloseDoesNotThrow(): Unit {
        let app = wen()
        app.get("/initial", {_: HttpRequest, res: HttpResponse => res.send("ok1")})
        let port: Int64 = 47823
        let listenDone = AtomicBool(false)
        spawn {
            try {
                app.listen(port)
            } catch (_: Exception) {
                ()
            }
            listenDone.store(true)
        }
        sleep(Duration.millisecond * 300)
        // 基线:运行期间确实拒绝注册(frozen=true)。如果这条断言不成立,说明
        // freeze 自身已经坏了,后面的复位断言就无意义。
        // app.get 在 frozen=true 时会抛 wen.IllegalStateException;但测试文件 import
        // 了 std.unittest 后 IllegalStateException 与 std 同名歧义,catch 父类 Exception
        // 即可 — app.get 的注册路径没有其他异常源。
        var midThrew = false
        try {
            app.get("/midflight", {_: HttpRequest, res: HttpResponse => res.send("mid")})
        } catch (_: Exception) {
            midThrew = true
        }
        @Assert(midThrew)

        app.close(timeoutMs: 1000)
        var i = 0
        while (i < 50 && !listenDone.load()) {
            sleep(Duration.millisecond * 20)
            i += 1
        }
        @Assert(listenDone.load())

        // 核心断言:close 完成后 frozen 必须被复位,允许追加路由。
        var afterCloseThrew = false
        try {
            app.get("/after", {_: HttpRequest, res: HttpResponse => res.send("ok2")})
        } catch (_: Exception) {
            afterCloseThrew = true
        }
        @Assert(!afterCloseThrew)
    }
}
