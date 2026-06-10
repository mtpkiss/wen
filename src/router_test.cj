package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RouterTest {
    // /users/:id should match /users/42 and capture id == "42".
    @TestCase
    func testParamExactMatch(): Unit {
        let pat = PathPattern.compile("/users/:id")
        match (pat.matchExact("/users/42")) {
            case Some(p) => @Assert(p["id"], "42")
            case None => @Assert(false) // expected a match
        }
    }

    // Too many segments must NOT match an exact pattern.
    @TestCase
    func testParamExactMismatchExtraSegment(): Unit {
        let pat = PathPattern.compile("/users/:id")
        match (pat.matchExact("/users/42/posts")) {
            case Some(_) => @Assert(false) // should not match
            case None => @Expect(true)
        }
    }

    // Wildcard segment consumes the remaining path.
    @TestCase
    func testWildcardMatch(): Unit {
        let pat = PathPattern.compile("/files/*")
        match (pat.matchExact("/files/a/b/c")) {
            case Some(_) => @Expect(true)
            case None => @Assert(false) // wildcard should match the tail
        }
    }

    // Prefix mount: /api matches /api/users as a prefix...
    @TestCase
    func testPrefixMountMatches(): Unit {
        let pat = PathPattern.compile("/api")
        match (pat.matchPrefix("/api/users")) {
            case Some(_) => @Expect(true)
            case None => @Assert(false) // prefix should match
        }
    }

    // ...but the same path is NOT an exact match.
    @TestCase
    func testPrefixNotExact(): Unit {
        let pat = PathPattern.compile("/api")
        match (pat.matchExact("/api/users")) {
            case Some(_) => @Assert(false) // exact should fail
            case None => @Expect(true)
        }
    }

    // Literal mismatch: /a/b does not match /a/c.
    @TestCase
    func testLiteralMismatch(): Unit {
        let pat = PathPattern.compile("/a/b")
        match (pat.matchExact("/a/c")) {
            case Some(_) => @Assert(false) // literal differs
            case None => @Expect(true)
        }
    }
}
