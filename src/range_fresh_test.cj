package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试 req.range(size)、req.fresh()/req.stale() 三个新增功能。
 *
 * range 解析结果用 rangeToStr 转成可比较字符串后断言;fresh 测试则手工把 req 与 res
 * 互相链接(模拟 app.handle 的行为),再设置条件请求头与响应缓存头进行判断。
 */

// 把 RangeRequest 转成便于断言的字符串。
func rangeToStr(r: RangeRequest): String {
    match (r) {
        case NoRange => "none"
        case Malformed => "malformed"
        case Unsatisfiable => "unsat"
        case Satisfiable(rs) =>
            var s = "ok:"
            for (br in rs) {
                s += "[${br.start}-${br.end}]"
            }
            s
    }
}

@Test
class RangeTest {
    // 没有 Range 头 → NoRange。
    @TestCase
    func testNoRangeHeader(): Unit {
        let req = HttpRequest("GET", "/x")
        @Assert(rangeToStr(req.range(1000)) == "none")
    }

    // 非 bytes 单位 / 缺少 "=" → Malformed。
    @TestCase
    func testMalformedUnit(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "items=0-10"
        @Assert(rangeToStr(req.range(1000)) == "malformed")
    }

    // "bytes=" 后为空 → Malformed。
    @TestCase
    func testMalformedEmptySpec(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes="
        @Assert(rangeToStr(req.range(1000)) == "malformed")
    }

    // 普通单区间 "bytes=0-99"。
    @TestCase
    func testSingleRange(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=0-99"
        @Assert(rangeToStr(req.range(1000)) == "ok:[0-99]")
    }

    // 仅起点 "bytes=500-" → 到末尾。
    @TestCase
    func testStartOnly(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=500-"
        @Assert(rangeToStr(req.range(1000)) == "ok:[500-999]")
    }

    // 末尾后缀 "bytes=-100" → 最后 100 字节。
    @TestCase
    func testSuffix(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=-100"
        @Assert(rangeToStr(req.range(1000)) == "ok:[900-999]")
    }

    // 后缀超过总长 → 起点夹到 0(返回整体)。
    @TestCase
    func testSuffixLargerThanSize(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=-5000"
        @Assert(rangeToStr(req.range(1000)) == "ok:[0-999]")
    }

    // 终点越界 → 截到 size-1。
    @TestCase
    func testEndClamped(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=0-5000"
        @Assert(rangeToStr(req.range(1000)) == "ok:[0-999]")
    }

    // 起点越界 → Unsatisfiable(应回 416)。
    @TestCase
    func testUnsatisfiable(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=2000-3000"
        @Assert(rangeToStr(req.range(1000)) == "unsat")
    }

    // 多区间:"bytes=0-0,-1"。
    @TestCase
    func testMultipleRanges(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=0-0,-1"
        @Assert(rangeToStr(req.range(1000)) == "ok:[0-0][999-999]")
    }

    // 非法子区间被跳过,合法的保留。
    @TestCase
    func testInvalidPartSkipped(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=abc-def,0-10"
        @Assert(rangeToStr(req.range(1000)) == "ok:[0-10]")
    }

    // size 为 0 时任何区间都不可满足。
    @TestCase
    func testZeroSize(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["range"] = "bytes=0-10"
        @Assert(rangeToStr(req.range(0)) == "unsat")
    }
}

@Test
class FreshTest {
    // 构造一对互相链接的 req/res,模拟 app.handle 的行为。
    func linked(method: String): (HttpRequest, HttpResponse) {
        let req = HttpRequest(method, "/x")
        let res = HttpResponse()
        res.req = Some(req)
        req.res = Some(res)
        return (req, res)
    }

    // If-None-Match 与 ETag 命中 → fresh,stale 取反。
    @TestCase
    func testFreshEtagMatch(): Unit {
        let (req, res) = linked("GET")
        res.headers["ETag"] = "\"abc\""
        req.headers["if-none-match"] = "\"abc\""
        @Assert(req.fresh())
        @Assert(!req.stale())
    }

    // ETag 不匹配 → 不新鲜。
    @TestCase
    func testStaleEtagMismatch(): Unit {
        let (req, res) = linked("GET")
        res.headers["ETag"] = "\"abc\""
        req.headers["if-none-match"] = "\"xyz\""
        @Assert(!req.fresh())
        @Assert(req.stale())
    }

    // If-None-Match 含多个候选,命中其一即可。
    @TestCase
    func testEtagMultipleCandidates(): Unit {
        let (req, res) = linked("GET")
        res.headers["ETag"] = "\"abc\""
        req.headers["if-none-match"] = "\"x\", \"abc\""
        @Assert(req.fresh())
    }

    // 弱校验前缀 W/ 在比对时被忽略。
    @TestCase
    func testEtagWeakMatch(): Unit {
        let (req, res) = linked("GET")
        res.headers["ETag"] = "\"abc\""
        req.headers["if-none-match"] = "W/\"abc\""
        @Assert(req.fresh())
    }

    // If-None-Match: * 命中任意 ETag。
    @TestCase
    func testEtagStar(): Unit {
        let (req, res) = linked("GET")
        res.headers["ETag"] = "\"whatever\""
        req.headers["if-none-match"] = "*"
        @Assert(req.fresh())
    }

    // 完全没有条件请求头 → 不新鲜。
    @TestCase
    func testNoConditionalHeaders(): Unit {
        let (req, res) = linked("GET")
        res.headers["ETag"] = "\"abc\""
        @Assert(!req.fresh())
    }

    // 非 GET/HEAD → 一律不新鲜。
    @TestCase
    func testNonGetMethod(): Unit {
        let (req, res) = linked("POST")
        res.headers["ETag"] = "\"abc\""
        req.headers["if-none-match"] = "\"abc\""
        @Assert(!req.fresh())
    }

    // 请求声明 no-cache → 强制不新鲜。
    @TestCase
    func testNoCacheRequest(): Unit {
        let (req, res) = linked("GET")
        res.headers["ETag"] = "\"abc\""
        req.headers["if-none-match"] = "\"abc\""
        req.headers["cache-control"] = "no-cache"
        @Assert(!req.fresh())
    }

    // 响应状态非 2xx/304 → 不新鲜。
    @TestCase
    func testNon2xxStatus(): Unit {
        let (req, res) = linked("GET")
        res.status(500)
        res.headers["ETag"] = "\"abc\""
        req.headers["if-none-match"] = "\"abc\""
        @Assert(!req.fresh())
    }

    // If-Modified-Since 与 Last-Modified 取值相等 → 新鲜。
    @TestCase
    func testLastModifiedEqual(): Unit {
        let (req, res) = linked("GET")
        let d = "Fri, 12 Jun 2026 00:40:55 GMT"
        res.headers["Last-Modified"] = d
        req.headers["if-modified-since"] = d
        @Assert(req.fresh())
    }

    // If-Modified-Since 与 Last-Modified 不同 → 不新鲜。
    @TestCase
    func testLastModifiedDiffer(): Unit {
        let (req, res) = linked("GET")
        res.headers["Last-Modified"] = "Fri, 12 Jun 2026 00:40:55 GMT"
        req.headers["if-modified-since"] = "Thu, 11 Jun 2026 00:00:00 GMT"
        @Assert(!req.fresh())
    }

    // 未绑定响应(脱离 app.handle 直接构造)→ 不新鲜。
    @TestCase
    func testNoResLinked(): Unit {
        let req = HttpRequest("GET", "/x")
        req.headers["if-none-match"] = "\"abc\""
        @Assert(!req.fresh())
        @Assert(req.stale())
    }
}
