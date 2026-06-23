package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * Trie 索引的边界用例。trie 仅承担「圈候选」,真正匹配走 PathPattern.matchExact;但 trie
 * 必须**无假阴**(命中的 layer 一定在候选里),否则路由会漏。这里的断言重点验证:
 *   - 静态 / 参数 / 可选段 / 通配 / 同位置多 :param 都能正确收 candidate
 *   - caseSensitive=false 时仍由 trie 圈中(literal 用 lowercase 存)
 *   - 路由表很大时仍能用 trie 直达单条候选
 */
@Test
class RouteTrieTest {
    // 给定一组 path 模式,构造 trie 并返回(layerIndex 即为注册顺序)。
    func buildTrie(patterns: Array<String>): RouteNode {
        let root = RouteNode()
        var i = 0
        while (i < patterns.size) {
            let pp = PathPattern.compile(patterns[i])
            insertRouteIntoTrie(root, pp.segments, i)
            i += 1
        }
        return root
    }

    // 候选索引集是否「至少包含」某个 layerIndex。语义:trie 必须把它列为候选(假阳无害)。
    func contains(cands: ArrayList<Int64>, idx: Int64): Bool {
        for (c in cands) {
            if (c == idx) {
                return true
            }
        }
        return false
    }

    // 静态段命中:/users/profile -> 命中 [0]。
    @TestCase
    func testLiteralHit(): Unit {
        let root = buildTrie(["/users/profile", "/users/:id"])
        let cands = collectTrieCandidates(root, pathSegments("/users/profile"))
        @Assert(contains(cands, 0))
    }

    // 参数段命中:/users/42 -> 命中 [1](:id 路由)。
    @TestCase
    func testParamHit(): Unit {
        let root = buildTrie(["/users/profile", "/users/:id"])
        let cands = collectTrieCandidates(root, pathSegments("/users/42"))
        @Assert(contains(cands, 1))
    }

    // 字面量与参数同位置时,匹配字面量的请求应同时收两条候选(由 matchExact 再二次过滤)。
    @TestCase
    func testLiteralAndParamAtSamePosition(): Unit {
        let root = buildTrie(["/users/profile", "/users/:id"])
        let cands = collectTrieCandidates(root, pathSegments("/users/profile"))
        @Assert(contains(cands, 0))
        @Assert(contains(cands, 1)) // :id 也匹配 "profile"
    }

    // 可选段 :page?:/posts 与 /posts/2 都应命中同一条路由。
    @TestCase
    func testOptionalSegmentHitsBoth(): Unit {
        let root = buildTrie(["/posts/:page?"])
        let candsBare = collectTrieCandidates(root, pathSegments("/posts"))
        @Assert(contains(candsBare, 0))
        let candsWith = collectTrieCandidates(root, pathSegments("/posts/2"))
        @Assert(contains(candsWith, 0))
    }

    // 通配段 *:/files/* 应命中任意深度。
    @TestCase
    func testWildcardMatchesAnyDepth(): Unit {
        let root = buildTrie(["/files/*"])
        let cands1 = collectTrieCandidates(root, pathSegments("/files/a.png"))
        @Assert(contains(cands1, 0))
        let cands2 = collectTrieCandidates(root, pathSegments("/files/dir/sub/x.txt"))
        @Assert(contains(cands2, 0))
    }

    // 大小写无关:trie 用 lowercase key 存,/Users/x 仍能圈出 /users/:id 候选。
    @TestCase
    func testCaseInsensitiveLiteralKey(): Unit {
        let root = buildTrie(["/users/:id"])
        let cands = collectTrieCandidates(root, pathSegments("/Users/42"))
        @Assert(contains(cands, 0))
    }

    // 完全不匹配的路径返回空候选,Router 端能直接走 404 路径。
    @TestCase
    func testNoMatchReturnsEmpty(): Unit {
        let root = buildTrie(["/users/profile", "/posts/:id"])
        let cands = collectTrieCandidates(root, pathSegments("/nope"))
        @Assert(cands.size == 0)
    }

    // 大路由表下命中最后一条仍只需常数级候选(O(M) 走 trie,M=请求段数)。
    @TestCase
    func testLargeTableHitsLastInConstant(): Unit {
        let app = wen()
        var i = 0
        while (i < 100) {
            app.get("/r${i}", {_: HttpRequest, res: HttpResponse => res.send("ok")})
            i += 1
        }
        // 路由的 layerIndex 与注册顺序一致(此处一对一)。
        let req = HttpRequest("GET", "/r99");
        req.path = "/r99"
        let res = HttpResponse();
        app.handle(req, res)
        @Assert(res.statusCode == 200)
        @Assert(res.body == "ok")
    }

    // 同位置多个 :param 配置(不同名 / 不同正则)都能存在,各自有自己的子树。
    @TestCase
    func testMultipleParamSlotsAtSamePosition(): Unit {
        let root = buildTrie(["/items/:id(\\d+)/edit", "/items/:slug/preview"])
        let candsA = collectTrieCandidates(root, pathSegments("/items/42/edit"))
        @Assert(contains(candsA, 0))
        let candsB = collectTrieCandidates(root, pathSegments("/items/abc/preview"))
        @Assert(contains(candsB, 1))
    }
}
