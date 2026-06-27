package wen

import std.unittest.*
import std.unittest.testmacro.*

/*
 * SseWriter / StreamWriter 单元测试:聚焦"流式输出对未受信任值的字段注入防护"。
 *
 * 单元测试场景下 res.conn 为 None,所有写入会退化为追加到 res.body — 这正好让
 * 我们能对最终字节流做断言。
 */
@Test
class StreamTest {
    // SseWriter.id(value) 在内部写出 "id: <value>\n"。如果 value 含字面 "\n",
    // 写入直接拼进流里 → 攻击者注入新的 SSE 字段(event / data / 任意),向同会话
    // 客户端推送伪造事件:典型场景如业务把外部用户名直接喂给 sse.id(req.attribute(
    // "userId") ?? "anon"),攻击者把 userId 设成 "1\nevent: logout" 让浏览器收到
    // 假的 logout 事件。修法:id / event / comment 入参先做 CRLF/NUL 校验。
    @TestCase
    func testSseIdRejectsLineFeed(): Unit {
        let res = HttpResponse()
        var injected = false
        res.sse {
            sse: SseWriter =>
                try {
                    sse.id("1\nevent: hijack\ndata: pwn")
                } catch (_: Exception) {
                    // 抛异常是合法防御:调用方把恶意输入塞进来,框架拒收。
                }
                sse.send("safe")
        }
        // 无论框架选择抛异常还是替换非法字符,最终 body 都不能出现注入的
        // "event: hijack" 行。
        @Assert(!res.body.contains("event: hijack"))
        injected = res.body.contains("event: hijack")
        @Assert(!injected)
    }

    // 同上,event 名称也必须拒 CRLF — 否则攻击者用 sse.event(userName, payload)
    // 同样能注入。
    @TestCase
    func testSseEventNameRejectsLineFeed(): Unit {
        let res = HttpResponse()
        res.sse {
            sse: SseWriter => try {
                sse.event("ok\nevent: shadow", "x")
            } catch (_: Exception) {
                ()
            }
        }
        @Assert(!res.body.contains("event: shadow"))
    }

    // comment 是 SSE 心跳常用接口,业务可能把请求 id / 错误描述等外部串塞进去 —
    // 同样必须拒 CRLF。
    @TestCase
    func testSseCommentRejectsLineFeed(): Unit {
        let res = HttpResponse()
        res.sse {
            sse: SseWriter => try {
                sse.comment("ping\ndata: forged")
            } catch (_: Exception) {
                ()
            }
        }
        @Assert(!res.body.contains("data: forged"))
    }

    // emitData 按行切的边界要识别 SSE 规范的全部行尾(\r\n、\n、\r)。当前只按 \n
    // 切,含 \r 的 data 会让 \r 之后的部分被浏览器当成"新行"解析,等同于注入新
    // 字段名。修法:同时按 \r 切。
    @TestCase
    func testSseDataSplitsOnCarriageReturn(): Unit {
        let res = HttpResponse()
        res.sse {
            sse: SseWriter => sse.send("hello\rsecret-line")
        }
        // 期望:"secret-line" 被识别为单独一行且带 "data: " 前缀,而不是被原样写出
        // 让浏览器把它解读为新字段。
        @Assert(res.body.contains("data: hello"))
        @Assert(res.body.contains("data: secret-line"))
    }

    // P1-14:无连接路径改字节缓冲 + 回调结束一次性刷出。多次写入必须按序完整拼接
    // (与旧的逐块 `res.body +=` 行为等价,但 O(n) 而非 O(n²))。
    @TestCase
    func testStreamMultiWriteConcatenatesInOrder(): Unit {
        let res = HttpResponse()
        res.stream {
            w: StreamWriter =>
                w.write("alpha")
                w.write("-")
                w.write("beta")
                w.writeBytes("-gamma".toArray())
        }
        @Assert(res.body == "alpha-beta-gamma")
    }

    // P1-14:字节缓冲先合并、再整体 String.fromUtf8。跨 writeBytes 拆开的多字节码点
    // 应还原成完整字符 —— 旧的逐块 fromUtf8 会把半个码点解成替换字符。"中" 的 UTF-8
    // 是 3 字节 [0xE4,0xB8,0xAD]。
    @TestCase
    func testStreamBytesSplitAcrossChunksDecodeAsWhole(): Unit {
        let res = HttpResponse()
        res.stream {
            w: StreamWriter =>
                w.writeBytes([UInt8(0xE4)])
                w.writeBytes([UInt8(0xB8), UInt8(0xAD)])
        }
        @Assert(res.body == "中")
    }
}
