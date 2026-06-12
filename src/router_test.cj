package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RouterTest {
    // 验证命名参数的精确匹配：模式 /users/:id 应当能匹配实际路径 /users/42，
    // 并把路径段 "42" 捕获到参数 id 上。匹配成功时取出 id，断言其值为 "42"；
    // 若返回 None 则说明匹配失败，用 @Assert(false) 让用例直接失败（注释提示“本应匹配”）。
    @TestCase
    func testParamExactMatch(): Unit {
        let pat = PathPattern.compile("/users/:id")
        match (pat.matchExact("/users/42")) {
            case Some(p) => @Assert(p["id"], "42")
            case None => @Assert(false) // 期望匹配成功，走到这里说明匹配失败
        }
    }

    // 验证精确匹配对段数的严格要求：模式 /users/:id 只有两段，
    // 而实际路径 /users/42/posts 多出一段，因此绝不能匹配成功。
    // 若意外匹配（Some 分支）则用 @Assert(false) 判定失败；正确情况应落入 None 分支。
    @TestCase
    func testParamExactMismatchExtraSegment(): Unit {
        let pat = PathPattern.compile("/users/:id")
        match (pat.matchExact("/users/42/posts")) {
            case Some(_) => @Assert(false) // 不应匹配：实际路径多出一段
            case None => @Expect(true)
        }
    }

    // 验证通配符 * 的行为：位于末尾的通配段会吞掉路径剩余的全部内容，
    // 因此模式 /files/* 能匹配 /files/a/b/c 这种多层级的尾部路径。
    // 期望走 Some 分支表示匹配成功；落入 None 则说明通配未生效，判定失败。
    @TestCase
    func testWildcardMatch(): Unit {
        let pat = PathPattern.compile("/files/*")
        match (pat.matchExact("/files/a/b/c")) {
            case Some(_) => @Expect(true)
            case None => @Assert(false) // 通配符应当匹配整个尾部路径
        }
    }

    // 验证前缀匹配（挂载场景）：以 /api 作为挂载前缀时，
    // matchPrefix 应当认为 /api/users 命中该前缀（前缀匹配只要求路径以模式开头）。
    // 期望走 Some 分支；落入 None 则说明前缀匹配未生效，判定失败。
    @TestCase
    func testPrefixMountMatches(): Unit {
        let pat = PathPattern.compile("/api")
        match (pat.matchPrefix("/api/users")) {
            case Some(_) => @Expect(true)
            case None => @Assert(false) // 前缀应当命中
        }
    }

    // 与上一用例对照：同样是 /api 对 /api/users，
    // 用 matchExact（精确匹配）时则不应命中——因为精确匹配要求整条路径完全相等，
    // 而 /api/users 比模式 /api 多出内容。若意外走 Some 分支则判定失败，正确应落入 None。
    @TestCase
    func testPrefixNotExact(): Unit {
        let pat = PathPattern.compile("/api")
        match (pat.matchExact("/api/users")) {
            case Some(_) => @Assert(false) // 精确匹配应当失败
            case None => @Expect(true)
        }
    }

    // 验证字面量段不匹配的情形：模式 /a/b 的第二段是字面量 "b"，
    // 与实际路径 /a/c 的第二段 "c" 不同，因此不应匹配。
    // 若意外走 Some 分支则判定失败，正确应落入 None。
    @TestCase
    func testLiteralMismatch(): Unit {
        let pat = PathPattern.compile("/a/b")
        match (pat.matchExact("/a/c")) {
            case Some(_) => @Assert(false) // 字面量段不同，不应匹配
            case None => @Expect(true)
        }
    }
}
