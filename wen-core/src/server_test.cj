package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * HttpServer 协议层单元测试:请求行 / 头部解析的严格校验、keep-alive 判定、
 * 响应序列化阶段的头部块编码。
 */
@Test
class ServerTest {
    // HTTP 请求行第三段必须严格匹配 "HTTP/<digit>.<digit>" 格式。"xx1.1" 这种
    // 串包含 "1.1" 子串,弱比对(.contains("1.1"))会把它当 HTTP/1.1 接受 — 与
    // 上游代理对版本的严格解析产生分歧,经典的请求走私入口。断言请求行
    // "GET / xx1.1" 在解析阶段就被 BadRequestException 拒掉(对外 400)。
    @TestCase
    func testRejectMalformedHttpVersion(): Unit {
        let server = HttpServer(wen())
        let raw = "GET / xx1.1\r\nHost: x\r\n\r\n".toArray()
        var caught = false
        try {
            server.parseRequest(raw)
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    // 同上,"HTTP-1.1" 这种把斜杠换成连字符的串也必须拒。校验等价于正则
    // "^HTTP/\d+\.\d+$"(强格式),不能用"含 HTTP 子串"这类宽松判定。
    @TestCase
    func testRejectHttpVersionMissingSlash(): Unit {
        let server = HttpServer(wen())
        let raw = "GET / HTTP-1.1\r\nHost: x\r\n\r\n".toArray()
        var caught = false
        try {
            server.parseRequest(raw)
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    // shouldKeepAlive 判定 HTTP/1.1 默认 keep-alive 必须用"== 精确匹配",不能用
    // .contains("1.1") 这种子串匹配:HTTP/2.1.1、HTTP/0.1.1 这类版本都不应被当
    // 作 1.1,否则非 1.1 客户端被误升级为 keep-alive,与上游代理对连接生命周期
    // 解读分歧,又是一条走私基底。这里同时验证 "HTTP/2.1.1" 被拒 + "HTTP/1.1"
    // 被接受。
    @TestCase
    func testShouldKeepAliveStrictMatch(): Unit {
        let server = HttpServer(wen())
        let req = HttpRequest("GET", "/")
        req.httpVersion = "HTTP/2.1.1"
        @Assert(!server.shouldKeepAlive(req))
        let req2 = HttpRequest("GET", "/")
        req2.httpVersion = "HTTP/1.1"
        @Assert(server.shouldKeepAlive(req2))
    }

    // 请求里出现两次 Host 头(`Host: a.com` + `Host: b.com`)必须直接 400 拒。
    // 否则 wen 取一个、上游代理取另一个,虚拟主机分发就分歧 — 攻击者可借此让反代
    // 转发到 a.com 的虚拟主机、wen 内部按 b.com 路由,经典的虚拟主机走私。
    // Content-Type 多值已采同款拒掉策略,Host 与之对齐。
    @TestCase
    func testRejectMultipleHostHeaders(): Unit {
        let server = HttpServer(wen())
        let raw = "GET / HTTP/1.1\r\nHost: a.com\r\nHost: b.com\r\n\r\n".toArray()
        var caught = false
        try {
            server.parseRequest(raw)
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    // 响应头序列化应按用户 set 的插入顺序输出 — 同份代码生成的响应字节流必须
    // 确定可复现。仓颉 HashMap 的迭代顺序未保证,如果直接遍历 headers map,同
    // 一份代码在不同进程实例可能产生不同字节流,影响响应字节级 ETag、上游缓存
    // 键、字节级回归测试的稳定性。断言连续 set X-A/X-B/X-C/X-D 后,序列化输出
    // 中四者顺序与插入顺序一致。
    @TestCase
    func testHeaderOrderIsInsertionOrder(): Unit {
        let res = HttpResponse()
        res.set("X-A", "1")
        res.set("X-B", "2")
        res.set("X-C", "3")
        res.set("X-D", "4")
        let bytes = buildHeadBlock(res)
        let s = String.fromUtf8(bytes)
        let ia = s.indexOf("X-A")
        let ib = s.indexOf("X-B")
        let ic = s.indexOf("X-C")
        let id = s.indexOf("X-D")
        match ((ia, ib, ic, id)) {
            case (Some(a), Some(b), Some(c), Some(d)) => @Assert(a < b && b < c && c < d)
            case _ => @Assert(false)
        }
    }

    // 请求头字节里出现非法 UTF-8 序列(裸 0x80–0xFF 单字节,不是合法的 UTF-8 起
    // 始字节),整体 fromUtf8 解码会抛通用 Exception 被外层 catch (_: Exception)
    // 映射成 500 内部错误。但协议层错误本应回 400 — 否则监控告警混乱、间接信息
    // 泄露(是 wen 的 bug 还是客户端非法请求难辨)。修后应抛 BadRequestException。
    @TestCase
    func testRejectsInvalidUtf8HeaderBytesAs400(): Unit {
        let server = HttpServer(wen())
        let prefix = "GET / HTTP/1.1\r\nHost: x\r\nX-Foo: ".toArray()
        let suffix = "\r\n\r\n".toArray()
        let buf = ArrayList<UInt8>()
        for (b in prefix) {
            buf.add(b)
        }
        buf.add(UInt8(0x80)) // 非法 UTF-8 单字节(continuation byte 单独出现)
        for (b in suffix) {
            buf.add(b)
        }
        var caught = false
        try {
            server.parseRequest(buf.toArray())
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    // 响应同时声明 Transfer-Encoding 与 Content-Length 时,RFC 7230 §3.3.3 要求
    // 接收方按 chunked 解析(忽略 CL)。但 wen 的 4 字节裸正文不是合法 chunk-size
    // 行,客户端 / 反代会解析失败 — 攻击者可借此让 wen 与上游 nginx 对响应边界
    // 产生分歧(响应方向的走私基底,反代缓存污染入口)。框架不应默默把两头都写
    // 出去:用户写了 TE 就尊重之,不再自动写 CL,或直接抛异常拒绝矛盾意图。
    @TestCase
    func testRejectsTransferEncodingPlusAutomaticContentLength(): Unit {
        let server = HttpServer(wen())
        let res = HttpResponse()
        res.set("Transfer-Encoding", "chunked")
        res.send("body")
        var bothPresent = false
        try {
            let bytes = server.serializeResponse(res)
            let text = String.fromUtf8(bytes)
            bothPresent = text.contains("Transfer-Encoding") && text.contains("Content-Length")
        } catch (_: Exception) {
            bothPresent = false
        }
        @Assert(!bothPresent)
    }

    // 1xx(100 Continue / 101 Switching Protocols 等)响应按 RFC 7230 §3.3.2
    // **MUST NOT** 含 Content-Length 头,且必须无 body。当前 serializeResponse
    // 只对 204 / 304 做 bodyless 抑制,1xx 整段未处理 — 生成的字节流违反协议契约,
    // 反代可能因此再生异常响应。修法:把 bodyless 条件扩展到 100..200。
    @TestCase
    func test1xxStatusHasNoBodyOrContentLength(): Unit {
        let server = HttpServer(wen())
        let res = HttpResponse()
        res.status(100).send("should-not-appear")
        let text = String.fromUtf8(server.serializeResponse(res))
        @Assert(!text.contains("should-not-appear"))
        @Assert(!text.contains("Content-Length"))
    }

    // parseQuery 对 key 也 urlDecode 会让 "?admin=user&%61dmin=root" 解码后变成
    // 同名 key 合并(last-wins → admin=root);上游 WAF 或反代按字节相等去重时只
    // 看到两个独立 key("admin" 与 "%61dmin"),都放行 — 攻击者借这条分歧把
    // ACL 检查的 "admin" 值绕过去。修法:key 不解码(以原始字节为 key),业务可
    // 用 urlDecode 自行后处理。
    @TestCase
    func testQueryKeyNotUrlDecodedAvoidsCollision(): Unit {
        let q = HashMap<String, String>()
        parseQuery("admin=user&%61dmin=root", q)
        // 期望:两个独立 key,不合并 — 第一个 "admin" 原样保留为 user。
        @Assert(q.size == 2)
        @Assert(q.get("admin") == Some("user"))
        @Assert(q.get("%61dmin") == Some("root"))
    }

    // 请求行 target 含 NUL(`GET /a\x00b HTTP/1.1`):RFC 3986 不允许 URI 含 CTL,
    // wen 入口若放行,C 语言风格的 fs 调用(File.writeTo 等)按 NUL 截断 → wen 看
    // 到 "/a\0b"、文件系统看到 "/a",路径解析分歧;同时日志按 NUL 截断,审计漏失。
    // parseRequest 在 target 解出后必须扫描 CTL 字符并拒。
    @TestCase
    func testRejectsTargetContainingNul(): Unit {
        let server = HttpServer(wen())
        let prefix = "GET /a".toArray()
        let suffix = "b HTTP/1.1\r\nHost: x\r\n\r\n".toArray()
        let buf = ArrayList<UInt8>()
        for (b in prefix) {
            buf.add(b)
        }
        buf.add(UInt8(0)) // NUL 嵌入 target
        for (b in suffix) {
            buf.add(b)
        }
        var caught = false
        try {
            server.parseRequest(buf.toArray())
        } catch (_: BadRequestException) {
            caught = true
        }
        @Assert(caught)
    }

    // 同上,target 含 CR 也必须拒(\r 单独出现会让一些代理解读为新行,与 wen 分歧)。
    @TestCase
    func testRejectsTargetContainingCR(): Unit {
        let server = HttpServer(wen())
        let prefix = "GET /a".toArray()
        let suffix = "b HTTP/1.1\r\nHost: x\r\n\r\n".toArray()
        let buf = ArrayList<UInt8>()
        for (b in prefix) {
            buf.add(b)
        }
        buf.add(UInt8(13)) // 单独 CR 嵌入 target
        for (b in suffix) {
            buf.add(b)
        }
        var caught = false
        try {
            server.parseRequest(buf.toArray())
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }

    // res.statusMessage 是 public var,业务代码理论上可以把它设成
    // "OK\r\nX-Injected: evil",而 buildHeadBlock 写状态行用的是 appendAscii — 没
    // 走 checkHeaderSafe(对比同函数对 headers k/v 都校验了)。结果响应字节里夹
    // 进了一条额外伪头,与 cookieSecret 同款"用户主动写恶意值也应被框架最后一道
    // 底线拦截"。修法:buildHeadBlock 序列化状态行前过一次 checkHeaderSafe;同时
    // 顺手把 statusCode 范围校验(100..999)。
    @TestCase
    func testStatusMessageRejectsCrLfAtSerialization(): Unit {
        let server = HttpServer(wen())
        let res = HttpResponse()
        res.statusMessage = "OK\r\nX-Injected: evil"
        var caught = false
        try {
            let _ = server.serializeResponse(res)
        } catch (_: Exception) {
            caught = true
        }
        @Assert(caught)
    }
}
