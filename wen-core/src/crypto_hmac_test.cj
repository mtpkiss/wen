package wen

import std.collection.*
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

    // bytesToHex 是 HMAC 输出 / cookie 签名等关键路径的固定格式化器,输出必须
    // 稳定。这条断言覆盖几个边界字节:全 0(00)、低 4 位最大(0f)、临界进位
    // (10)、全 1(ff)、奇数值(aa) — 确认对每字节的高低 nibble 排列、十六
    // 进制小写化都符合既定行为,避免某次重构悄悄改成大写 / 调换 nibble 顺序。
    @TestCase
    func testBytesToHexBehaviourUnchanged(): Unit {
        let bytes: Array<UInt8> = [UInt8(0), UInt8(15), UInt8(16), UInt8(255), UInt8(170)]
        let s = bytesToHex(bytes)
        @Assert(s == "000f10ffaa")
    }

    // secure_random 的种子收集会把当前时间等 Int64 值喂进 appendInt64。若时间回
    // 拨到 1970 年前(测试环境时钟错乱、容器迁移),Int64 会成负数 — 实现不能
    // 用 "UInt64(Int64)" 这种会在负值上抛异常的转换,否则全局 SecureRandom 单例
    // 直接构造失败,整个框架启动不可用。断言对 -1 与 Int64.Min 都不抛,且写入
    // 的字节数对齐(每次 8 字节)。
    @TestCase
    func testAppendInt64HandlesNegative(): Unit {
        let buf = ArrayList<UInt8>()
        var threw = false
        try {
            appendInt64(buf, -1)
            appendInt64(buf, Int64.Min)
        } catch (_: Exception) {
            threw = true
        }
        @Assert(!threw)
        @Assert(buf.size == 16)
    }
}
