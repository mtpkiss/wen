package wen

import std.unittest.*
import std.unittest.testmacro.*

@Test
class CryptoHmacTest {
    // SHA-256 已知向量(NIST):空串与 "abc"。
    @TestCase
    func testSha256Vectors(): Unit {
        @Assert(bytesToHex(sha256("".toArray())) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        @Assert(bytesToHex(sha256("abc".toArray())) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // 跨分组边界的较长输入(56 字节,触发额外填充块)。
    @TestCase
    func testSha256LongerInput(): Unit {
        @Assert(bytesToHex(sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".toArray())) ==
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    // HMAC-SHA256 已知向量(RFC 4231 风格):key="key",msg=经典 pangram。
    @TestCase
    func testHmacVector(): Unit {
        @Assert(hmacSha256Hex("key", "The quick brown fox jumps over the lazy dog") ==
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    }

    // 超过分组长度(64 字节)的密钥会先被哈希,仍应产出确定结果。
    @TestCase
    func testHmacLongKey(): Unit {
        let longKey = "0123456789012345678901234567890123456789012345678901234567890123456789"
        let sig = hmacSha256Hex(longKey, "data")
        @Assert(sig.size == 64) // 32 字节 -> 64 个十六进制字符
    }
}
