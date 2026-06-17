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
| 4. 路由表规模 | 1 / 10 / 50 / 100 / 500 条路由,命中最后一条 + 500 条 404——trie 索引让派发耗时与路由表规模解耦 |
| 4a. 中间件链 | 含 `requestId + cors + helmet + etag` 的典型业务管线派发,体现真实场景额外成本 |
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
> 相对关系。(wen 0.3.0 · cjc 1.1.3 cjnative · release · x86_64-w64-mingw32)

```
benchmark                                iters           ns/op           ops/sec

0. 标尺
noop (闭包调用基线)                    500,000         7.95 ns     125,719,745/s
单个 HashMap<String,String> 分配       500,000       769.53 ns       1,299,486/s

1. 对象分配
HttpRequest + HttpResponse 构造        500,000      6587.04 ns         151,813/s

2. 路由匹配
静态三段 /users/profile/settings       500,000      2272.26 ns         440,089/s
双参数 /users/:id/posts/:pid           500,000      4758.99 ns         210,128/s
通配 /files/*                          500,000      2087.16 ns         479,120/s
pathSegments 拆分(5 段)               500,000      1580.88 ns         632,557/s

3. 请求派发
派发 静态命中                          100,000     21610.89 ns          46,272/s
派发 双参数命中 + JSON                 100,000     32139.60 ns          31,114/s
派发 未命中 (404)                      100,000     12741.49 ns          78,483/s

4. 路由表规模 (trie 索引:命中应与规模解耦)
1 条路由 (命中)                        100,000     16063.80 ns          62,251/s
10 条路由 (命中最后)                   100,000     17354.27 ns          57,622/s
50 条路由 (命中最后)                    50,000     17462.59 ns          57,265/s
100 条路由 (命中最后)                   50,000     16672.91 ns          59,977/s
500 条路由 (命中最后)                   50,000     16189.36 ns          61,768/s
500 条路由 (未命中 404)                 50,000     11938.36 ns          83,763/s

4a. 中间件链 (requestId + cors + helmet + etag)
命中 + 4 中间件链                      100,000     46290.96 ns          21,602/s

5. JSON 序列化
小对象 (3 字段)                        200,000      5672.78 ns         176,280/s
中对象 (5 字段 + 数组)                 200,000     12813.76 ns          78,041/s

6. JSON 解析
小文档 (3 字段)                        200,000      4294.23 ns         232,870/s
中文档 (3 对象数组)                     50,000     16567.62 ns          60,358/s
解析 + 再序列化 往返                    50,000     39487.59 ns          25,324/s

7. URL / Base64
urlDecode ASCII                        500,000       896.51 ns       1,115,437/s
urlDecode UTF-8 (你好世界)             200,000      1606.41 ns         622,505/s
base64 编码 (48B)                      200,000      4622.85 ns         216,316/s
base64 解码 (64ch)                     200,000      9391.96 ns         105,640/s
```

## 怎么读这张表(以及优化方向)

1. **派发耗时与路由表规模解耦**(0.3.0 起):第 4 分区里 1 / 10 / 50 / 100 / 500 条
   命中最后一条都落在 **16–17 µs**,500 条 404 是 **12 µs**——trie 索引把"找候选"
   从 O(N) 变成 O(M+K)(M=请求段数、K=候选数,都与总路由数无关)。这是从"对标
   Express 88%"升到"原生高性能"的硬支撑。
   → 不再有"扫到最后一层"的退化曲线;数千条路由的应用也只付一份固定派发开销。

2. **当前的主要成本是「分配 + 闭包」,不是匹配**。`HashMap` 单次分配 ~770 ns;
   `HttpRequest` 含 6 张 HashMap + 几个 ArrayList/Array,加 `HttpResponse` 合计约
   9 个集合 ≈ **6.6 µs**——构造耗时基本等于「集合个数 × 单位分配成本」。**派发
   静态命中 ≈ 22 µs ≈ 构造 + 匹配 + handler 闭包**。
   → 后续优化首选:让 `query/params/attributes/locals/cookies` 改为**懒初始化**
   (首次访问再建),空请求能省掉大半集合分配。

3. **中间件链是叠加的固定成本**。`requestId + cors + helmet + etag` 四个内置中间件
   把派发推到 **46 µs**(单中间件平均 +6 µs)——这部分本身是用户决定的:不需要的
   中间件不挂即可。要进一步压缩可在 `helmet` 上传 `frameOptions: ""` 等关掉若干头。

4. **JSON / 编解码量级正常**:小对象序列化 ~5.7 µs、小文档解析 ~4.3 µs,主要也是
   `ArrayList<UInt8>` / 字符串拼接的分配开销;非热点,暂不必动。

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
