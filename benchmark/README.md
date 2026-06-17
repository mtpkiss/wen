# Wen 基准测试

Wen 框架热点路径的**微基准(micro-benchmark)**。度量的是用户会高频触达的公开
API 的单次耗时——对象分配、路由匹配、请求派发、JSON 编解码、URL/Base64 编解码,
**不含 socket I/O**(网络吞吐另见文末「端到端压测」)。

这是一个独立的 cjpm 可执行模块,通过 `path` 依赖引用上层的 `wen` 库,因此不会干扰
框架自身的构建与测试。

## 运行

```bash
cd benchmark
cjpm run
```

默认即 release(优化)构建;约 20~30 秒跑完,输出一张对齐的结果表。

> 构建时会有一行 `unused function: 'main'` 警告,来自 `wen` 仓库里被 gitignore 的
> 本地 demo `src/main.cj`,与基准无关,可忽略。全新 clone(无 main.cj)同样能跑。

## 度量了什么

| 分区 | 内容 |
|------|------|
| 0. 标尺 | noop(闭包调用地板)、单个 `HashMap` 分配——给其余数字提供参照系 |
| 1. 对象分配 | 每请求必付的 `HttpRequest` + `HttpResponse` 构造 |
| 2. 路由匹配 | `PathPattern.matchExact`:静态 / 双参数 / 通配;`pathSegments` 拆分 |
| 3. 请求派发 | `app.handle` 全链路(匹配 + 处理器):静态命中 / 参数命中+JSON / 404 |
| 4. 路由表规模 | 1 / 10 / 50 条路由,命中最后一条(trie 改造后已与路由数解耦,1/10/50 几乎同耗时) |
| 5. JSON 序列化 | `JsonObj -> String`:小对象 / 含嵌套数组的中对象 |
| 6. JSON 解析 | `String -> JsonValue`:小文档 / 对象数组 / 解析+再序列化往返 |
| 7. URL/Base64 | `urlDecode`(ASCII / UTF-8)、`base64` 编 / 解码 |

## 方法

- **预热**:每项先跑 `warmup` 轮(不计时),预热分配器与缓存,再跑 N 轮计时。
- **计时**:用单调时钟 `std.time.MonoTime` 量「整段 N 轮」的总耗时,折算成 ns/op
  与 ops/s——单次调用太快,逐次计时会被时钟分辨率淹没,measure-the-whole-loop 更稳。
- **防消除**:每轮结果连同循环下标一起汇入一个 `sink` 并最终打印,避免优化器认定
  「结果无人使用」而把循环体整段消除(dead-code elimination)。
- **构建**:cjnative 后端,默认 release。`noop` 行(~8ns)即harness 的纯开销地板,
  用来验证其余数字确实是被测代码的真实耗时,而非测量噪声。

## 一次参考结果

> 单线程、in-process、含每请求对象分配。**绝对值随机器/版本而变**,看的是量级与
> 相对关系。(cjc 1.1.3 cjnative · release · x86_64-w64-mingw32)

```
benchmark                                iters           ns/op           ops/sec

0. 标尺
noop (闭包调用基线)                    500,000         7.89 ns     126,688,119/s
单个 HashMap<String,String> 分配       500,000       728.86 ns       1,372,002/s

1. 对象分配
HttpRequest + HttpResponse 构造        500,000      6617.18 ns         151,121/s

2. 路由匹配
静态三段 /users/profile/settings       500,000      2170.32 ns         460,761/s
双参数 /users/:id/posts/:pid           500,000      4011.06 ns         249,310/s
通配 /files/*                          500,000      1968.71 ns         507,946/s
pathSegments 拆分(5 段)               500,000      1554.35 ns         643,353/s

3. 请求派发
派发 静态命中                          100,000     21815.84 ns          45,838/s
派发 双参数命中 + JSON                 100,000     29652.02 ns          33,724/s
派发 未命中 (404)                      100,000     23535.47 ns          42,489/s

4. 路由表规模 (命中最后一条)
1 条路由                               100,000     10908.67 ns          91,670/s
10 条路由                              100,000     26615.63 ns          37,571/s
50 条路由                               50,000    101346.41 ns           9,867/s

5. JSON 序列化
小对象 (3 字段)                        200,000      5827.54 ns         171,599/s
中对象 (5 字段 + 数组)                 200,000     13014.29 ns          76,838/s

6. JSON 解析
小文档 (3 字段)                        200,000      4393.29 ns         227,619/s
中文档 (3 对象数组)                     50,000     16612.75 ns          60,194/s
解析 + 再序列化 往返                    50,000     39705.62 ns          25,185/s

7. URL / Base64
urlDecode ASCII                        500,000       912.10 ns       1,096,368/s
urlDecode UTF-8 (你好世界)             200,000      1733.14 ns         576,987/s
base64 编码 (48B)                      200,000      4662.50 ns         214,477/s
base64 解码 (64ch)                     200,000      9466.06 ns         105,640/s
```

## 怎么读这张表(以及优化方向)

1. **当前是「分配受限」**。单个 `HashMap` 分配就要 ~729ns;`HttpRequest` 内含 6 张
   HashMap + 若干 ArrayList/Array,加上 `HttpResponse`,合计约 9 个集合 ≈ 6.6µs——
   构造耗时基本等于「集合个数 × 单位分配成本」。**派发 ~22µs ≈ 构造 + 匹配×2 + 闭包**。
   → 优化首选:让 `HttpRequest` 的 `query/params/attributes/locals/cookies` 改为
   **懒初始化**(首次访问再建),空请求就能省掉大半分配。

2. **路由匹配是线性扫描,且每层都重新拆一遍路径**。表里 1/10/50 条路由近似线性
   (每多一条约 +1.9µs),根源是每个 `Layer.tryMatch` 都调用 `pathSegments` 重新
   把请求 path 拆段。此外 `runChain` 命中时跑一次 `tryMatch`,`runNormal` 取参数时
   **又跑一次**(双重匹配)。
   → 优化方向:每请求把 path **拆一次段缓存复用**;第一次匹配时就把捕获的 params
   一并留存,避免二次匹配。

3. **JSON/编解码量级正常**,小对象序列化 ~5.8µs、小文档解析 ~4.4µs,主要也是
   `ArrayList<UInt8>`/字符串拼接的分配开销;非热点,暂不必动。

这些都是**单线程 in-process**数字;真实服务器吞吐还要叠加 socket 读写、请求解析、
响应序列化与多连接并发。

## 端到端压测(下一步)

要测真实的 HTTP 吞吐/延迟,需要一个外部压测工具对**真正跑起来的服务器**施压
(本机目前未安装,任选其一:[`bombardier`](https://github.com/codesenberg/bombardier)、
[`wrk`](https://github.com/wg/wrk)、[`hey`](https://github.com/rakyll/hey)、
[`oha`](https://github.com/hatoo/oha)):

```bash
# 终端 1:启动一个最小服务器(把 wen 的 output-type 临时设为 executable 跑 demo,
#         或在 benchmark/ 里另写一个只注册 GET "/" 的 main 并 app.listen)
cjpm run

# 终端 2:加压 15 秒、64 并发
bombardier -c 64 -d 15s http://localhost:8080/
# 或
wrk -t4 -c64 -d15s http://localhost:8080/
```

关注 **req/s** 与 **P50/P99 延迟**。把上面的微基准当作「单请求理论地板」,端到端
数字落在它之上、差距即 socket 与并发调度的开销。
