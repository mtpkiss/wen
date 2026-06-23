---
title: Session 存储扩展
nav_order: 5
---

# Session 存储扩展指南

`wen` 默认使用 `MemorySessionStore`(线程安全、带 TTL 与上限淘汰),适合开发与单实例
小服务。本页讲在生产环境下把会话挪到外部存储(Redis / 数据库 / 文件)的方法 ——
实现 `SessionStore` 接口即可。

## 为什么要自定义存储

`MemorySessionStore` 有三个固有限制:

- **重启即丢**:进程内存,无持久化
- **不可横向扩展**:多实例 / 多进程部署时各自的内存隔离,sid 在 A 实例签发、B 实例认不出
- **受单机内存上限**:虽然有 `maxSessions` FIFO 淘汰兜底,但内存仍是硬上限

切到 Redis / 数据库 / 文件等外部存储即可解决。下面是接口契约与实现要点。

## SessionStore 接口

```cangjie
public interface SessionStore {
    func load(id: String): ?HashMap<String, String>
    func save(id: String, values: HashMap<String, String>): Unit
    func destroy(id: String): Unit
    func newId(): String
    // 0.4.0 起;有默认实现,自定义 store 不必重写也能编译通过
    func touch(id: String): Unit { /* 默认转调 load + save */ }
}
```

| 方法 | 行为契约 |
|---|---|
| `load(id)` | 不存在或已过期返回 `None`;**不应抛异常**,后端不可用时返 `None` 让请求按"新会话"继续 |
| `save(id, values)` | **覆盖式**写入(全量替换);可顺手刷新 TTL |
| `destroy(id)` | 删除;**幂等**(不存在静默成功)。用于实现登出 |
| `newId()` | 返回不可预测的 sid;**必须用 CSPRNG**(直接调框架的 `secureRandomHex(16)` 即得 128 位) |
| `touch(id)` | 仅刷新"最近访问时间",不重写会话数据本体(下节详述) |

### 关于 `touch` 与 dirty(0.4.0 新增)

每次请求结束时,session 中间件会**判断本次有没有改过数据**,据此选择 `save` 或 `touch`:

- **dirty = true**(请求中调过 `sess.set(k,v)` / `sess.remove(k)` / `sess.regenerate()`)
  → 调 `store.save(id, values)`,把整张 hash 写回
- **dirty = false**(请求只读会话)→ 调 `store.touch(id)`,只刷新过期时间

为什么重要:大量请求(尤其登录态校验)是**只读**的。如果每次都 `save` 整张 hash:

- Redis 是 `HSET key f1 v1 f2 v2 ...` + `EXPIRE key 86400` 两条命令,还可能跟并发请求竞争覆盖
- 数据库是一条 UPDATE 写全列

而 `touch` 的最优实现:**只发 `EXPIRE key 86400`**(Redis)或 `UPDATE sessions SET expires_at=? WHERE id=?`(SQL)
—— **一条命令、一行写、零数据竞争**。这是 [wen-core/src/session.cj](../wen-core/src/session.cj) 在
P0-E 修复的"每请求无脑 save"写放大问题。

**默认实现**(读出来再写回)能保证既有自定义 store 编译通过,但**性能等价于 save**。
为生产环境编写自定义 store 时,**请重写 `touch` 为单条 EXPIRE / UPDATE**。

## 注册自定义存储

把自定义 store 实例传给 `session()`:

```cangjie
let app = wen()
app.cookieSecret = "change-me"               // session 用签名 sid,需先设密钥
app.use(session(MyRedisStore("redis://localhost:6379")))
```

`session(store, cookieName!, path!, maxAge!, secure!, sameSite!, httpOnly!)` 支持调 sid Cookie
的属性(默认 `sid` / `/` / 不过期 / 非 secure / 无 SameSite / `HttpOnly=true`)。

读写会话:

```cangjie
app.get("/whoami", { req, res =>
    match (req.session) {
        case Some(s) => res.send(s.get("user") ?? "anon")
        case None => res.status(500).send("session middleware not registered")
    }
})

app.post("/login", { req, res =>
    match (req.session) {
        case Some(s) =>
            s.set("user", "alice")              // 触发 dirty,本次结束调 save
            s.regenerate()                       // 换发新 sid,防 session fixation
            res.send("ok")
        case None => res.status(500).end()
    }
})
```

## 最小可运行实现:文件系统 store

下面是一个用文件系统持久化的最小实现,**只为演示接口落地结构**(性能差、不适合生产):

```cangjie
package myapp

import wen.*
import std.collection.*
import std.fs.*
import std.sync.*

public class FileSessionStore <: SessionStore {
    let root: String
    let lock = ReentrantMutex()

    public init(root: String) {
        this.root = root
        // 调用方自行确保目录存在
    }

    public func load(id: String): ?HashMap<String, String> {
        lock.lock()
        try {
            let path = pathOf(id)
            if (!fileExists(path)) { return None }
            // 内容是简易 KV 格式:k=v,每行一条;真实场景请用 JSON 序列化
            let raw = readToString(path)
            let map = HashMap<String, String>()
            for (line in raw.split("\n")) {
                if (line.isEmpty()) { continue }
                let (k, v) = splitOnce(line, "=")
                map[k] = v
            }
            return Some(map)
        } finally { lock.unlock() }
    }

    public func save(id: String, values: HashMap<String, String>): Unit {
        lock.lock()
        try {
            var s = ""
            for ((k, v) in values) { s += "${k}=${v}\n" }
            writeToFile(pathOf(id), s)
        } finally { lock.unlock() }
    }

    public func destroy(id: String): Unit {
        lock.lock()
        try {
            let path = pathOf(id)
            if (fileExists(path)) { deleteFile(path) }
        } finally { lock.unlock() }
    }

    // 框架已内置 CSPRNG,直接复用,无需自造
    public func newId(): String { return secureRandomHex(16) }

    // 重写 touch 为只 update mtime —— 比默认 (load + save) 快得多
    public func touch(id: String): Unit {
        lock.lock()
        try {
            let path = pathOf(id)
            if (fileExists(path)) { utime(path) /* 平台相关:setLastModified */ }
        } finally { lock.unlock() }
    }

    func pathOf(id: String): String { return "${root}/${id}.sess" }
}
```

> 文件名以 `std.fs` 中的具体 API 为准(`File.exists / File.delete / File.writeText / File.readText`
> 等具体名称随 stdlib 版本调整),本示例用伪函数名简化。真实代码中需要替换为当前 cjc
> 标准库可用 API。

## 集成 Redis(设计要点)

不附完整代码(Cangjie Redis 客户端生态尚在早期);列出**接口要怎么映射**:

| `SessionStore` 方法 | Redis 命令 | 备注 |
|---|---|---|
| `load(id)` | `HGETALL session:{id}` | 空返回 → `None`;命中后**顺手** `EXPIRE session:{id} ttl` 续期 |
| `save(id, values)` | `DEL session:{id}` + `HSET session:{id} k1 v1 ...` + `EXPIRE ... ttl` | DEL 防止旧字段残留;三命令打 pipeline |
| `destroy(id)` | `DEL session:{id}` | 幂等 |
| `newId()` | 框架 `secureRandomHex(16)`,**不要用 INCR**(可预测) |
| **`touch(id)`** | `EXPIRE session:{id} ttl` | **关键优化点**:相比默认实现的 `HGETALL + DEL + HSET + EXPIRE`,这里只发 1 条命令 |

**键前缀**:用 `session:` 之类前缀避免与业务键冲突;多租户场景再加租户前缀。

**过期策略**:依赖 Redis 自身 TTL,无需应用层定时清理。`expiresAt` 字段不必存。

## 集成关系数据库(设计要点)

表结构:

```sql
CREATE TABLE sessions (
    id          VARCHAR(64)  PRIMARY KEY,
    data        TEXT NOT NULL,                            -- JSON 序列化 HashMap
    expires_at  TIMESTAMP    NOT NULL,
    INDEX idx_expires_at (expires_at)
);
```

| `SessionStore` 方法 | SQL |
|---|---|
| `load(id)` | `SELECT data FROM sessions WHERE id=? AND expires_at>NOW()` |
| `save(id, values)` | MySQL: `INSERT ... ON DUPLICATE KEY UPDATE`;Postgres: `INSERT ... ON CONFLICT DO UPDATE` |
| `destroy(id)` | `DELETE FROM sessions WHERE id=?` |
| `newId()` | 框架 `secureRandomHex(16)` |
| **`touch(id)`** | `UPDATE sessions SET expires_at=? WHERE id=?` —— **单行 UPDATE,不重写 data 列** |

**清理过期**:开个定时任务 `DELETE FROM sessions WHERE expires_at<NOW()` 即可;或 MySQL 用
`EVENT`,Postgres 用 `pg_cron`。

## 序列化:HashMap ↔ 字符串

`values: HashMap<String, String>` 已经是扁平 string→string,大多数后端可直接存:

- **Redis**:直接用 HSET,每个字段一列,**无需序列化**
- **SQL TEXT 列**:JSON 是默认选择(`parseJson` / `JsonObj` 框架自带);键值都是 string,
  序列化用 `JsonObj().put(k, v)...build().toJsonString()`,反序列化用 `parseJson(text)`
  再迭代 `keys()`
- **二进制后端**(LMDB 之类):同上,但用 MessagePack / Protobuf 性能更好(需第三方库)

## 实现要点清单

- **线程安全**:wen 默认服务器是多线程的,store 方法要承受并发调用。Redis 单命令原子,
  无需额外锁;SQL 用连接池本身解决;**内存/文件** store 需要自加 `Mutex` / `ReentrantMutex`
- **错误处理**:`load` / `save` / `destroy` / `touch` **不应向上抛异常**(否则会冒泡到错误中间件 + 500)。
  catch 后:`load` 返 `None`、写类方法静默失败 + 日志。`SessionStore` 接口不保证后端总可用
- **不存敏感数据**:sid 可能泄露;敏感字段(密码、tokens)别直接进 session,只存"已认证 user id"
  之类的引用,真数据另存安全位置
- **大小适度**:每次请求都(可能)写一次。会话数据控制在几 KB 内,不要塞业务对象大块缓存
- **`newId` 必须 CSPRNG**:直接用框架的 `secureRandomHex(16)`,不要用 `std.random.Random`
  (后者可预测,被攻击者预测后能伪造他人 sid)
- **`touch` 必须优化**:生产 store 不重写 `touch` 等于退化到 `save` 性能 —— P0-E 的工作完全失效

## 参考实现

- [wen-core/src/session.cj](../wen-core/src/session.cj) —— `Session` / `SessionStore` / `MemorySessionStore` 完整源码
- [MemorySessionStore](../wen-core/src/session.cj) 自身就是一个 SessionStore 实现,带 `ttlSeconds` /
  `maxSessions` FIFO 淘汰 / 加锁清理,可直接对照
- [中间件参考 — session](./middleware.md#sessionstore-wen) —— `session()` 工厂的全部选项

## 相关资源

- [Express.js session 文档](https://expressjs.com/en/resources/middleware/session.html) ——
  Node 生态的等价 API,设计取舍可对照
- [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html)
