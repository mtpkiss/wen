package wen

import std.collection.*
import std.sync.*
import std.time.*

/*
 * 会话(session)支持。
 *
 * session() 中间件为每个请求关联一个 Session(以字符串键值存放会话数据),并用一个
 * 签名的 "sid" Cookie 把浏览器与服务端的会话挂钩:
 *   - 进入时:从签名 Cookie 读出 sid 并验签,据此从 SessionStore 载入既有会话;
 *     没有有效会话则新建一个(分配随机 sid,标记为 new)。
 *   - 处理后:把会话数据回存到 store;若是新会话,则下发签名的 sid Cookie。
 *
 * 前置条件:设置 app.cookieSecret(sid Cookie 经 HMAC 签名,客户端无法伪造),否则签名/
 * 验签无法进行。Cookie 解析已内置,无需再注册 cookieParser。
 *
 * 默认的 MemorySessionStore 把会话存在进程内存里(重启即失),仅适合单实例/开发场景;
 * 生产可自行实现 SessionStore 接口接入 Redis、数据库等。内存实现用 Mutex 保护,
 * 因为服务器是多线程处理连接的,会话表会被并发读写。
 */

// 一次请求对应的会话对象:带一个 id 和一组字符串键值数据。
public class Session {
    // id / isNew 在请求处理过程中可能因 regenerate() 而变化,因此是 var:
    //   - regenerate() 会把 id 切换到新值、isNew 置 true,从而触发 sid Cookie 重新下发。
    //   - values 内容随之迁移,处理器手上的 sess 引用语义不变。
    public var id: String
    let values: HashMap<String, String>
    public var isNew: Bool
    // regenerate() 标记:由中间件在 next() 返回后处理。
    var regenerateRequested: Bool = false

    init(id: String, values: HashMap<String, String>, isNew: Bool) {
        this.id = id
        this.values = values
        this.isNew = isNew
    }

    // 读取会话中某个键的值;不存在返回 None。
    public func get(key: String): ?String {
        return values.get(key)
    }

    // 写入/覆盖会话中某个键的值。
    public func set(key: String, value: String): Unit {
        values[key] = value
    }

    // 删除会话中某个键。
    public func remove(key: String): Unit {
        values.remove(key)
    }

    // 在「认证边界」(典型为用户登录成功后)调用,为当前会话换发一枚新的随机 sid:
    //   - 旧 sid 在 store 中销毁;
    //   - 数据(values)迁移到新 sid;
    //   - 标记 isNew,使 session 中间件在响应结束时下发新的签名 sid Cookie。
    // 这能挫败「会话固定攻击」:即使攻击者先设了一个已知 sid 的 Cookie,登录后 sid
    // 立即被替换,旧 sid 失效。本方法只**记录意图**,真正的 destroy/newId/setCookie
    // 由 session() 中间件在 next() 返回后统一执行,以避免与处理器中其它会话操作竞争。
    public func regenerate(): Unit {
        this.regenerateRequested = true
    }
}

// 会话存储后端的抽象接口。自定义存储(Redis/DB 等)实现此接口即可接入 session()。
public interface SessionStore {
    // 按 id 载入会话数据;不存在返回 None。
    func load(id: String): ?HashMap<String, String>
    // 按 id 保存会话数据(覆盖)。
    func save(id: String, values: HashMap<String, String>): Unit
    // 销毁某个会话。
    func destroy(id: String): Unit
    // 生成一个新的、唯一的会话 id。
    func newId(): String
}

// 单个会话在存储里的内部表示。`lastAccess` 用于 TTL 滑动过期(每次 load/save 都刷新)。
class SessionEntry {
    var values: HashMap<String, String>
    var lastAccess: Int64

    init(values: HashMap<String, String>, lastAccess: Int64) {
        this.values = values
        this.lastAccess = lastAccess
    }
}

// 进程内存实现的会话存储(线程安全,用 Mutex 保护)。
//
// 配额(默认全关、向后兼容):
//   - ttlSeconds:**滑动**过期窗口,>0 时,任何「上次访问后超过 N 秒」的会话被视为不存在
//     并在 load/save 时惰性清理。-1/0 表示永不过期。
//   - maxSessions:容量上限,>0 时,save 引入新会话且容量超额时,FIFO 淘汰最旧。
//
// 「满了怎么办」选 evict 而非 reject:save 发生在响应处理之后,reject 只能让会话「静默
// 失效」(下个请求又是新会话);evict 在 save 里淘汰最旧,零中间件改动、对正常用户无感。
public class MemorySessionStore <: SessionStore {
    let data = HashMap<String, SessionEntry>()
    let order = ArrayList<String>() // 按首次写入顺序;FIFO 淘汰从头部取
    let lock = Mutex()
    let ttlSeconds: Int64
    let maxSessions: Int64

    public init(ttlSeconds!: Int64 = -1, maxSessions!: Int64 = -1) {
        this.ttlSeconds = ttlSeconds
        this.maxSessions = maxSessions
    }

    public func load(id: String): ?HashMap<String, String> {
        lock.lock()
        try {
            sweepExpiredLocked()
            match (data.get(id)) {
                case Some(entry) =>
                    if (isExpiredLocked(entry)) {
                        removeFromOrderLocked(id)
                        data.remove(id)
                        return None
                    }
                    // 滑动过期:每次访问都续命。
                    entry.lastAccess = nowSec()
                    return Some(copyMap(entry.values))
                case None => return None
            }
        } finally {
            lock.unlock()
        }
    }

    public func save(id: String, values: HashMap<String, String>): Unit {
        lock.lock()
        try {
            sweepExpiredLocked()
            let isNew = !data.contains(id)
            data[id] = SessionEntry(copyMap(values), nowSec())
            if (isNew) {
                order.add(id)
                if (maxSessions > 0) {
                    while (order.size > maxSessions) {
                        let oldId = order[0]
                        order.remove(0..1)
                        data.remove(oldId)
                    }
                }
            }
        } finally {
            lock.unlock()
        }
    }

    public func destroy(id: String): Unit {
        lock.lock()
        try {
            data.remove(id)
            removeFromOrderLocked(id)
        } finally {
            lock.unlock()
        }
    }

    // 128 位 sid。**安全关键**:经 secureRandomHex(应用层 CSPRNG)生成,以保证攻击者
    // 无法从自己拿到的 sid 反推内部状态、预测他人 sid(详见 secure_random.cj)。
    public func newId(): String {
        return secureRandomHex(16)
    }

    // 当前会话数(诊断 / 测试用)。
    public func size(): Int64 {
        lock.lock()
        try {
            return data.size
        } finally {
            lock.unlock()
        }
    }

    private func nowSec(): Int64 {
        return DateTime.now().toUnixTimeStamp().toSeconds()
    }

    private func isExpiredLocked(entry: SessionEntry): Bool {
        if (ttlSeconds <= 0) {
            return false
        }
        return nowSec() - entry.lastAccess >= ttlSeconds
    }

    // 顺序队列前面是最旧的;从头扫到第一个未过期就停下,O(已过期数)。
    private func sweepExpiredLocked(): Unit {
        if (ttlSeconds <= 0) {
            return
        }
        let n = nowSec()
        while (order.size > 0) {
            let oldId = order[0]
            match (data.get(oldId)) {
                case Some(e) => if (n - e.lastAccess >= ttlSeconds) {
                    order.remove(0..1)
                    data.remove(oldId)
                } else {
                    return
                }
                case None => order.remove(0..1)
            }
        }
    }

    private func removeFromOrderLocked(id: String): Unit {
        var i = 0
        while (i < order.size) {
            if (order[i] == id) {
                order.remove(i..(i + 1))
                return
            }
            i += 1
        }
    }
}

// 构造 session 中间件,使用指定的存储后端。可选具名参数定制 sid Cookie:
//   cookieName  Cookie 名(默认 "sid")
//   path        Path 属性(默认 "/")
//   maxAge      Max-Age 秒数;默认 -1 表示不设(会话 Cookie,关闭浏览器即失)
//   secure      是否仅 HTTPS 回传(默认 false;生产 HTTPS 站点应设 true)
//   sameSite    SameSite 策略(默认空,不输出;可设 "Lax"/"Strict"/"None")
//   httpOnly    是否禁止脚本读取(默认 true)
// sid Cookie 始终 HMAC 签名,故仍需先设 app.cookieSecret。
public func session(store: SessionStore, cookieName!: String = "sid", path!: String = "/", maxAge!: Int64 = -1,
    secure!: Bool = false, sameSite!: String = "", httpOnly!: Bool = true): Middleware {
    return {
        req: HttpRequest, res: HttpResponse, next: Next =>
            let sess = loadOrCreateSession(req, store, cookieName)
            req.session = Some(sess)
            next()
            // 处理器若调用了 sess.regenerate(),在此换发新 sid:销毁旧 id、把数据
            // 在内部迁移到新 id、并强制下发新 Cookie。**必须在 save 之前换 id**,
            // 否则数据会被以旧 id 重新存回,旧记录又复活。
            if (sess.regenerateRequested) {
                store.destroy(sess.id)
                sess.id = store.newId()
                sess.isNew = true
                sess.regenerateRequested = false
            }
            // 请求处理完毕后回存会话;新会话再下发一枚签名的 sid Cookie。
            store.save(sess.id, sess.values)
            if (sess.isNew) {
                res.cookie(cookieName, sess.id, path: path, maxAge: maxAge, httpOnly: httpOnly, secure: secure,
                    sameSite: sameSite, signed: true)
            }
    }
}

// 构造 session 中间件,使用默认的进程内存存储。
public func session(): Middleware {
    return session(MemorySessionStore())
}

// 依据签名 sid Cookie 载入既有会话,或新建一个会话。cookieName 为 sid Cookie 的名字。
func loadOrCreateSession(req: HttpRequest, store: SessionStore, cookieName: String): Session {
    match (req.signedCookie(cookieName)) {
        case Some(id) => match (store.load(id)) {
            case Some(vals) => return Session(id, vals, false)
            case None => return Session(store.newId(), HashMap<String, String>(), true)
        }
        case None => return Session(store.newId(), HashMap<String, String>(), true)
    }
}

// 复制一份键值表(避免会话对象与存储内部共享同一引用,在多线程下更安全)。
func copyMap(src: HashMap<String, String>): HashMap<String, String> {
    let out = HashMap<String, String>()
    for ((k, v) in src) {
        out[k] = v
    }
    return out
}

// 把一个 UInt64 转成 16 位小写十六进制字符串(大端,固定宽度)。
func toHex64(v: UInt64): String {
    let digits = "0123456789abcdef"
    var s = ""
    var i = 60
    while (i >= 0) {
        let nib = Int64((v >> UInt64(i)) & UInt64(0xF))
        s += digits[nib..(nib + 1)]
        i -= 4
    }
    return s
}
