# Session 存储扩展指南

> **适用对象**: 需要在生产环境中使用 session 的开发者  
> **前置知识**: 了解 wen 框架基本概念、中间件使用、Session 基础用法  
> **估计阅读时间**: 10 分钟

---

## 📋 概述

默认情况下，`wen` 使用 **内存存储** (`MemorySessionStore`) 来保存会话数据。这在开发环境和单实例部署时工作良好，但在生产环境中存在以下问题：

1. **重启丢失** - 服务器重启后所有会话数据丢失
2. **无法扩展** - 多进程/多服务器部署时，每个实例的内存会话不共享
3. **内存限制** - 会话数据存储在内存中，受限于服务器内存大小

为解决这些问题，你需要将会话数据存储到 **外部存储** 中，如：
- Redis（推荐）
- 关系型数据库（MySQL、PostgreSQL 等）
- 文档数据库（MongoDB 等）
- 其他键值存储

好消息是，`wen` 提供了 **`SessionStore` 接口**，让你可以轻松实现自定义会话存储后端。

---

## 🔧 SessionStore 接口

所有会话存储后端都需要实现 `SessionStore` 接口。该接口定义了 4 个方法：

```cangjie
public interface SessionStore {
    // 按 id 载入会话数据；不存在返回 None
    func load(id: String): ?HashMap<String, String>
    
    // 按 id 保存会话数据（覆盖）
    func save(id: String, values: HashMap<String, String>): Unit
    
    // 销毁某个会话
    func destroy(id: String): Unit
    
    // 生成一个新的、唯一的会话 id
    func newId(): String
}
```

### 方法详解

#### 1. `load(id: String): ?HashMap<String, String>`
- **作用**: 根据会话 ID 从存储中加载会话数据
- **参数**: `id` - 会话 ID（通常是随机生成的 128 位十六进制字符串）
- **返回**: 
  - `Some(values)` - 会话存在，返回键值对映射
  - `None` - 会话不存在或已过期
- **注意**: 该方法不应该抛出异常，如果存储不可用应返回 `None`

#### 2. `save(id: String, values: HashMap<String, String>): Unit`
- **作用**: 保存会话数据到存储中
- **参数**: 
  - `id` - 会话 ID
  - `values` - 会话数据键值对
- **注意**: 
  - 应该实现为 **覆盖式保存**（即更新已存在的会话）
  - 可以考虑设置 TTL（过期时间）以实现会话自动过期

#### 3. `destroy(id: String): Unit`
- **作用**: 从存储中删除指定会话
- **参数**: `id` - 要删除的会话 ID
- **注意**: 
  - 如果会话不存在，应该静默成功（幂等操作）
  - 用于实现「退出登录」功能

#### 4. `newId(): String`
- **作用**: 生成一个新的、唯一的会话 ID
- **返回**: 会话 ID 字符串
- **注意**: 
  - 必须保证唯一性（通常使用加密安全随机数）
  - 默认实现使用两个 64 位随机数生成 128 位十六进制字符串

---

## 📝 实现自定义 SessionStore

### 步骤 1：创建自定义存储类

以下是一个 **模板代码**，展示了实现 `SessionStore` 的基本结构：

```cangjie
package myproject

import wen.*
import std.collection.*

// 自定义会话存储（以 Redis 为例）
public class RedisSessionStore <: SessionStore {
    // Redis 客户端（假设你有一个 Redis 客户端库）
    let redis: RedisClient
    
    // 会话键前缀（避免与其他键冲突）
    let keyPrefix: String
    
    // 会话过期时间（秒）
    let ttlSeconds: Int64
    
    public init(redis: RedisClient, keyPrefix!: String = "session:", 
                ttlSeconds!: Int64 = 86400) {
        this.redis = redis
        this.keyPrefix = keyPrefix
        this.ttlSeconds = ttlSeconds
    }
    
    // 从 Redis 加载会话
    public func load(id: String): ?HashMap<String, String> {
        let key = this.keyPrefix + id
        
        // 获取哈希表所有字段和值
        let data = this.redis.hgetall(key)
        
        if (data.isEmpty()) {
            return None  // 会话不存在
        }
        
        // 转换为 HashMap<String, String>
        let values = HashMap<String, String>()
        for ((field, value) in data) {
            values[field] = value
        }
        
        // 刷新过期时间（可选）
        this.redis.expire(key, this.ttlSeconds)
        
        return Some(values)
    }
    
    // 保存会话到 Redis
    public func save(id: String, values: HashMap<String, String>): Unit {
        let key = this.keyPrefix + id
        
        // 先删除旧数据（确保覆盖）
        this.redis.del(key)
        
        // 转换为 Redis 哈希表格式并存储
        let hashData = HashMap<String, String>()
        for ((k, v) in values) {
            hashData[k] = v
        }
        
        this.redis.hset(key, hashData)
        
        // 设置过期时间
        this.redis.expire(key, this.ttlSeconds)
    }
    
    // 销毁会话
    public func destroy(id: String): Unit {
        let key = this.keyPrefix + id
        this.redis.del(key)
    }
    
    // 生成新的会话 ID（可以复用默认实现）
    public func newId(): String {
        // 使用默认的随机数生成器
        let rng = Random()
        return toHex64(rng.nextUInt64()) + toHex64(rng.nextUInt64())
    }
}

// 辅助函数：将 UInt64 转为 16 位十六进制字符串
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
```

---

### 步骤 2：使用自定义存储

实现自定义存储后，将其传递给 `session()` 中间件即可：

```cangjie
package myproject

import wen.*
import redis.*  // 假设有 Redis 客户端库

main(): Int64 {
    let app = wen()
    
    // 1. 创建 Redis 客户端
    let redis = RedisClient("localhost", 6379)
    
    // 2. 创建自定义会话存储
    let sessionStore = RedisSessionStore(redis, 
                                       keyPrefix: "myapp:session:",
                                       ttlSeconds: 7200)  // 2 小时过期
    
    // 3. 注册中间件（按顺序）
    app.use(cookieParser())
    app.use(session(sessionStore))  // 传入自定义存储
    
    // 4. 使用会话
    app.get("/login", { req, res =>
        match (req.session) {
            case Some(s) =>
                s.set("userId", "12345")
                s.set("username", "alice")
                res.send("Logged in! Session ID: ${s.id}")
            case None => res.send("No session?")
        }
    })
    
    app.listen(8080)
    return 0
}
```

---

## 🎯 实战示例

### 示例 1：Redis 会话存储（生产推荐）

Redis 是会话存储的 **最佳选择**，因为：
- ✅ 内存存储，读写极快
- ✅ 支持自动过期（TTL）
- ✅ 支持分布式部署
- ✅ 支持持久化（可选）

#### 前置条件
你需要一个 Cangjie 的 Redis 客户端库。如果还没有，可以考虑：
1. 使用 FFI 调用 hiredis（C 客户端）
2. 自己实现一个简单的 Redis 协议客户端（RESP）
3. 等待社区提供 Redis 客户端库

#### 完整实现（伪代码）

```cangjie
// redis-session-store.cj
package myproject

import wen.*
import std.collection.*
import std.time.*

public class RedisSessionStore <: SessionStore {
    let redis: RedisClient  // 你的 Redis 客户端
    let keyPrefix: String
    let ttlSeconds: Int64
    
    public init(redis: RedisClient, keyPrefix!: String = "session:",
                ttlSeconds!: Int64 = 86400) {
        this.redis = redis
        this.keyPrefix = keyPrefix
        this.ttlSeconds = ttlSeconds
    }
    
    public func load(id: String): ?HashMap<String, String> {
        let key = this.keyPrefix + id
        
        // 检查键是否存在
        if (!this.redis.exists(key)) {
            return None
        }
        
        // 获取所有哈希字段
        let fields = this.redis.hkeys(key)
        if (fields.isEmpty()) {
            return None
        }
        
        // 批量获取值
        let values = this.redis.hmget(key, fields)
        
        // 构建映射
        let result = HashMap<String, String>()
        for (i in 0..fields.size) {
            result[fields[i]] = values[i]
        }
        
        // 刷新 TTL
        this.redis.expire(key, this.ttlSeconds)
        
        return Some(result)
    }
    
    public func save(id: String, values: HashMap<String, String>): Unit {
        let key = this.keyPrefix + id
        
        // 使用 HMSET 批量设置
        let data = HashMap<String, String>()
        for ((k, v) in values) {
            data[k] = v
        }
        
        this.redis.hset(key, data)
        this.redis.expire(key, this.ttlSeconds)
    }
    
    public func destroy(id: String): Unit {
        let key = this.keyPrefix + id
        this.redis.del(key)
    }
    
    public func newId(): String {
        // 可以使用 Redis 的 INCR 生成 ID，或使用随机字符串
        // 这里使用随机字符串（与默认实现相同）
        let rng = Random()
        return toHex64(rng.nextUInt64()) + toHex64(rng.nextUInt64())
    }
}
```

---

### 示例 2：MySQL 会话存储

如果你的应用已经使用了 MySQL 数据库，可以直接用数据库存储会话。

#### 数据库表结构

```sql
CREATE TABLE sessions (
    id VARCHAR(128) PRIMARY KEY,
    data TEXT NOT NULL,          -- 序列化的会话数据
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    expires_at TIMESTAMP         -- 过期时间
);

-- 可选：定时清理过期会话
CREATE EVENT cleanup_expired_sessions
ON SCHEDULE EVERY 1 HOUR
DO DELETE FROM sessions WHERE expires_at < NOW();
```

#### Cangjie 实现

```cangjie
// mysql-session-store.cj
package myproject

import wen.*
import std.collection.*
import database.*  // 假设有 MySQL 客户端库

public class MySQLSessionStore <: SessionStore {
    let db: DatabaseClient
    let tableName: String
    
    public init(db: DatabaseClient, tableName!: String = "sessions") {
        this.db = db
        this.tableName = tableName
    }
    
    public func load(id: String): ?HashMap<String, String> {
        let sql = "SELECT data FROM ${this.tableName} WHERE id = ? AND expires_at > NOW()"
        let result = this.db.query(sql, [id])
        
        if (result.isEmpty()) {
            return None
        }
        
        // 反序列化 data 字段（假设存储的是 JSON 格式）
        let dataJson = result[0]["data"]
        let values = deserializeFromJson(dataJson)  // 你需要实现这个函数
        
        return Some(values)
    }
    
    public func save(id: String, values: HashMap<String, String>): Unit {
        // 序列化为 JSON
        let dataJson = serializeToJson(values)  // 你需要实现这个函数
        
        // 计算过期时间（当前时间 + 24 小时）
        let expiresAt = currentTime() + 86400  // 假设有时间函数
        
        // 使用 REPLACE 或 INSERT ... ON DUPLICATE KEY UPDATE
        let sql = """
            INSERT INTO ${this.tableName} (id, data, expires_at) 
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE data = VALUES(data), expires_at = VALUES(expires_at)
        """
        this.db.execute(sql, [id, dataJson, expiresAt])
    }
    
    public func destroy(id: String): Unit {
        let sql = "DELETE FROM ${this.tableName} WHERE id = ?"
        this.db.execute(sql, [id])
    }
    
    public func newId(): String {
        let rng = Random()
        return toHex64(rng.nextUInt64()) + toHex64(rng.nextUInt64())
    }
}

// 辅助函数：序列化 HashMap 为 JSON
func serializeToJson(values: HashMap<String, String>): String {
    var json = "{"
    var first = true
    for ((k, v) in values) {
        if (!first) {
            json += ","
        }
        json += "\"${k}\":\"${v}\""
        first = false
    }
    json += "}"
    return json
}

// 辅助函数：从 JSON 反序列化为 HashMap
func deserializeFromJson(json: String): HashMap<String, String> {
    // 简单实现：解析 JSON 对象
    // 实际使用时建议使用成熟的 JSON 解析库
    let values = HashMap<String, String>()
    // ... 解析逻辑
    return values
}
```

---

### 示例 3：MongoDB 会话存储

MongoDB 的文档模型非常适合存储会话数据。

#### 文档结构

```json
{
  "_id": "session_id_here",
  "data": {
    "userId": "12345",
    "username": "alice"
  },
  "createdAt": ISODate("2026-06-12T10:00:00Z"),
  "expiresAt": ISODate("2026-06-13T10:00:00Z")
}
```

#### Cangjie 实现（伪代码）

```cangjie
// mongodb-session-store.cj
package myproject

import wen.*
import mongodb.*  // 假设有 MongoDB 客户端库

public class MongoDBSessionStore <: SessionStore {
    let collection: MongoCollection
    
    public init(db: MongoDatabase, collectionName!: String = "sessions") {
        this.collection = db.collection(collectionName)
        
        // 创建索引（自动过期）
        this.collection.createIndex(
            ["expiresAt": 1],
            ["expireAfterSeconds": 0]
        )
    }
    
    public func load(id: String): ?HashMap<String, String> {
        let filter = ["_id": id, "expiresAt": ["$gt": currentTime()]]
        let doc = this.collection.findOne(filter)
        
        if (doc.isEmpty()) {
            return None
        }
        
        // 提取 data 字段
        let data = doc["data"].asDocument()
        let values = HashMap<String, String>()
        
        for ((k, v) in data) {
            values[k] = v.asString()
        }
        
        return Some(values)
    }
    
    public func save(id: String, values: HashMap<String, String>): Unit {
        // 构建文档
        let dataDoc = Document()
        for ((k, v) in values) {
            dataDoc[k] = v
        }
        
        let doc = Document()
        doc["_id"] = id
        doc["data"] = dataDoc
        doc["updatedAt"] = currentTime()
        
        // 设置过期时间
        doc["expiresAt"] = currentTime() + 86400
        
        // upsert（存在则更新，不存在则插入）
        let filter = ["_id": id]
        this.collection.replaceOne(filter, doc, ["upsert": true])
    }
    
    public func destroy(id: String): Unit {
        let filter = ["_id": id]
        this.collection.deleteOne(filter)
    }
    
    public func newId(): String {
        let rng = Random()
        return toHex64(rng.nextUInt64()) + toHex64(rng.nextUInt64())
    }
}
```

---

## ⚙️ 高级话题

### 1. 会话序列化格式

在 `save()` 方法中，你需要决定如何序列化会话数据（`HashMap<String, String>`）。

**选项 1：JSON 格式（推荐）**
- ✅ 人类可读，便于调试
- ✅ 跨语言兼容
- ❌ 序列化/反序列化有性能开销

**选项 2：二进制格式（如 MessagePack）**
- ✅ 更高效
- ❌ 不可读

**选项 3：URL-encoded 格式**
- ✅ 简单
- ❌ 不支持复杂数据结构

**建议**: 使用 JSON 格式，除非你有极端的性能需求。

---

### 2. 会话过期策略

#### 方案 A：存储端自动过期（推荐）
- Redis: 使用 `EXPIRE` 命令
- MongoDB: 使用 TTL 索引
- MySQL: 使用事件调度器或定时任务

**优点**: 自动清理，无需手动管理  
**缺点**: 依赖存储引擎的特定功能

#### 方案 B：应用端检查过期
在 `load()` 方法中检查 `expires_at` 字段，如果过期则返回 `None`。

**优点**: 不依赖存储引擎  
**缺点**: 需要手动清理过期数据

---

### 3. 并发安全

如果你的应用是多线程的（如 wen 的默认服务器），需要确保会话存储操作是 **线程安全**的。

**建议**:
- Redis 单命令是原子的，无需额外同步
- 数据库操作使用事务（如果需要多个操作）
- 避免在我们的存储类中引入全局锁（会影响性能）

---

### 4. 错误处理

`SessionStore` 的方法不应该抛出异常。如果存储不可用（如 Redis 断开连接），应该：

1. **记录错误日志**
2. **返回默认值**（`load()` 返回 `None`，`save()` 和 `destroy()` 静默失败）
3. **可选**：实现重试逻辑

```cangjie
public func load(id: String): ?HashMap<String, String> {
    try {
        // ... 正常逻辑
    } catch (e: Exception) {
        println("ERROR: Failed to load session ${id}: ${e.message}")
        return None  // 返回空，让应用继续运行
    }
}
```

---

### 5. 性能优化

#### 缓存热门会话
如果存储后端较慢（如数据库），可以在自定义存储类中添加一个 **内存缓存层**：

```cangjie
public class CachedSessionStore <: SessionStore {
    let backend: SessionStore  // 实际存储后端
    let cache: HashMap<String, HashMap<String, String>>  // 内存缓存
    let lock: Mutex
    
    public init(backend: SessionStore) {
        this.backend = backend
        this.cache = HashMap<String, HashMap<String, String>>()
        this.lock = Mutex()
    }
    
    public func load(id: String): ?HashMap<String, String> {
        // 先查缓存
        this.lock.lock()
        try {
            match (this.cache.get(id)) {
                case Some(v) => return Some(copyMap(v))
                case None => ()
            }
        } finally {
            this.lock.unlock()
        }
        
        // 缓存未命中，查后端
        match (this.backend.load(id)) {
            case Some(v) =>
                // 写入缓存
                this.lock.lock()
                try {
                    this.cache[id] = copyMap(v)
                } finally {
                    this.lock.unlock()
                }
                return Some(v)
            case None => return None
        }
    }
    
    // ... 其他方法也需要更新缓存
}
```

---

## 📚 最佳实践

### ✅ 推荐做法

1. **总是设置会话过期时间** - 避免会话数据无限增长
2. **使用会话 ID 签名** - 配合 `app.cookieSecret` 使用签名 Cookie
3. **不要在会话中存储敏感信息** - 会话 ID 可能被窃取
4. **定期清理过期会话** - 即使存储引擎支持自动过期
5. **监控会话存储性能** - 关注延迟和错误率

### ❌ 避免的做法

1. **不要在会话中存储大量数据** - 每次请求都会加载/保存
2. **不要使用可预测的会话 ID** - 使用加密安全随机数
3. **不要忽略错误处理** - 存储后端可能随时不可用
4. **不要在 `newId()` 中引入性能瓶颈** - 它会被频繁调用

---

## 🔗 相关资源

- [wen 官方文档 - 会话中间件](../docs/middleware.md#sessionstore)
- [Express.js session 文档](https://expressjs.com/en/resources/middleware/session.html)
- [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html)

---

## 🤝 贡献

如果你实现了一个通用性强的会话存储后端（如 Redis、MySQL、MongoDB），欢迎贡献到 wen 项目！

**贡献步骤**:
1. Fork wen 仓库
2. 在 `src/store/` 目录下创建你的存储实现
3. 添加单元测试
4. 更新文档
5. 提交 Pull Request

---

**最后更新**: 2026-06-12  
**维护者**: wen 开发团队
