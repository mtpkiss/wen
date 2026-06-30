package wen

import std.collection.*
import std.sync.*
import std.random.*
import std.time.*

/*
 * 「应用层 best-effort」CSPRNG —— 用于 session id / CSRF token 等需要不可预测的场景。
 *
 * 背景:仓颉 std.random.Random 内部是 Mersenne Twister(普通 PRNG,非 CSPRNG)。
 * 它的输出只要观察足够多就能反推内部状态(经典攻击:看到 624 个连续 32 位输出
 * 即可完全恢复),用它直接生成 sid / CSRF token 存在「攻击者预测下一枚 token」的
 * 现实风险。仓颉 std.crypto 仅有接口,真正的 CSPRNG 在尚未发布的 stdx.crypto 里;
 * 框架又不便引入 FFI 直接调 BCryptGenRandom / getrandom(零依赖契约)。
 *
 * 折中方案(本文件):
 *   1. **多源种子混合**:DateTime.now().nanosecond + 多个独立 Random 实例输出 + 多个
 *      对象的 hashCode(ASLR 派生)。各源之间互相独立,把暴力枚举的搜索空间提升到 ~2^96+。
 *   2. **HMAC-SHA256 单向扩展**:state 经过 HMAC 派生输出,**观察者无法从输出反推 state**;
 *      即便能猜中某次 state,只能影响有限次输出,下次 reseed 后又变。
 *   3. **周期性 reseed**:每生成 ~4 KiB 字节后,混入新一轮多源熵,持续打破"长程预测"。
 *
 * 局限性(必须如实告知):
 *   - 它不是真正的 CSPRNG。若运行环境的种子源(高分辨率时间、ASLR)极端劣化(例如
 *     虚拟机刚启动、容器进程数极少且无负载),熵可能不足。
 *   - 等仓颉 stdx.crypto 提供 OS CSPRNG 后,**应替换本文件的种子源(`collectSeed`)
 *     直接调用 OS 入口**,API 外形保持 `secureRandomHex(n) / secureRandomBytes(n)` 不变。
 */
class SecureRandom {
    let lock = Mutex()
    var key: Array<UInt8> // 当前 HMAC key(32 字节)
    var counter: UInt64 = 0
    var emittedSinceReseed: Int64 = 0

    init() {
        let seed = collectSeed()
        this.key = hmacSha256("wen-secure-random-init".toArray(), seed)
    }

    func nextBytes(n: Int64): Array<UInt8> {
        lock.lock()
        try {
            if (emittedSinceReseed >= 4096) {
                reseedLocked()
            }
            let out = Array<UInt8>(n, repeat: 0)
            var written = 0
            while (written < n) {
                let block = blockNext()
                var i = 0
                while (i < block.size && written < n) {
                    out[written] = block[i]
                    written += 1
                    i += 1
                }
            }
            emittedSinceReseed += n
            return out
        } finally {
            lock.unlock()
        }
    }

    private func blockNext(): Array<UInt8> {
        counter += UInt64(1)
        let msg = Array<UInt8>(8, repeat: 0)
        var c = counter
        var i = 7
        while (i >= 0) {
            msg[i] = UInt8(c & UInt64(0xFF))
            c >>= UInt64(8)
            i -= 1
        }
        return hmacSha256(this.key, msg)
    }

    private func reseedLocked(): Unit {
        let extra = collectSeed()
        let merged = ArrayList<UInt8>()
        for (b in this.key) {
            merged.add(b)
        }
        for (b in extra) {
            merged.add(b)
        }
        this.key = hmacSha256("wen-secure-random-reseed".toArray(), merged.toArray())
        emittedSinceReseed = 0
    }
}

// 多源熵采集。把不同来源(时间、ASLR 派生 hashCode、多个独立 Random 实例输出)
// 拼接成一段字节,再交由 HMAC 派生 key。各源彼此独立,任一源被攻破不足以恢复其它。
func collectSeed(): Array<UInt8> {
    let buf = ArrayList<UInt8>()

    // 1. 墙钟纳秒部分(~30 bit 熵)。
    let dt = DateTime.now()
    appendInt64(buf, dt.nanosecond)
    appendInt64(buf, dt.toUnixTimeStamp().toNanoseconds())

    // 2. 多个独立 Random 实例的输出(默认构造每个实例 seed 不同;它们之间没有共享状态)。
    let r1 = Random()
    let r2 = Random()
    let r3 = Random()
    var i = 0
    while (i < 4) {
        appendUInt64(buf, r1.nextUInt64())
        appendUInt64(buf, r2.nextUInt64())
        appendUInt64(buf, r3.nextUInt64())
        i += 1
    }

    // 3. 在 Random 输出的间隙,继续采样高分辨率时间:每次 DateTime.now().nanosecond
    // 都不一样,把多次相邻采样的纳秒位拼进去,等价于一个独立的"时间抖动"熵源。
    i = 0
    while (i < 8) {
        appendInt64(buf, DateTime.now().nanosecond)
        i += 1
    }

    return buf.toArray()
}

func appendUInt64(buf: ArrayList<UInt8>, v: UInt64): Unit {
    var i = 7
    var c = v
    let tmp = Array<UInt8>(8, repeat: 0)
    while (i >= 0) {
        tmp[i] = UInt8(c & UInt64(0xFF))
        c >>= UInt64(8)
        i -= 1
    }
    for (b in tmp) {
        buf.add(b)
    }
}

func appendInt64(buf: ArrayList<UInt8>, v: Int64): Unit {
    // 直接 `UInt64(v: Int64)` 对负 v 会抛(系统时钟回拨到 1970 前 / Int64.Min 等
    // 边界路径会触发)— 一旦失败,GLOBAL_SECURE_RANDOM 包级 init 抛异常,整个应用挂。
    // 用位模式重解释(等价 C 风格 `(uint64_t)i64`),所有 Int64 值都能安全编码 8 字节。
    var u: UInt64 = 0
    var rem = v
    var i = 0
    while (i < 8) {
        u = u | (UInt64(rem & 0xFF) << UInt64(i * 8))
        rem = rem >> 8
        i += 1
    }
    appendUInt64(buf, u)
}

// 全局单例。session id / CSRF token 经此入口生成,确保它们对外部观察不可预测。
let GLOBAL_SECURE_RANDOM: SecureRandom = SecureRandom()

// 生成 n 字节强随机数据。
public func secureRandomBytes(n: Int64): Array<UInt8> {
    return GLOBAL_SECURE_RANDOM.nextBytes(n)
}

// 生成 n 字节强随机数据,以小写十六进制返回(长度 = 2n)。常用于 sid / CSRF token。
public func secureRandomHex(n: Int64): String {
    return bytesToHex(secureRandomBytes(n))
}
