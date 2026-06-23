package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ReqProxyTest {
    // 默认(不信任代理)时,协议恒为 "http"、secure 为 false,且忽略伪造的
    // X-Forwarded-Proto 头。
    @TestCase
    func testProtocolDefaultHttp(): Unit {
        let app = wen()
        let req = HttpRequest("GET", "/");
        req.app = Some(app)
        req.headers["x-forwarded-proto"] = "https"
        @Assert(req.protocol() == "http")
        @Assert(!req.secure())
    }

    // 开启信任代理后,protocol/secure 采信 X-Forwarded-Proto。
    @TestCase
    func testProtocolForwardedWithTrust(): Unit {
        let app = wen()
        app.trustProxy = true
        let req = HttpRequest("GET", "/");
        req.app = Some(app)
        req.headers["x-forwarded-proto"] = "https"
        @Assert(req.protocol() == "https")
        @Assert(req.secure())
    }

    // 不信任代理时,ips() 为空,clientIp() 回退到直连对端地址。
    @TestCase
    func testIpsEmptyWithoutTrust(): Unit {
        let app = wen()
        let req = HttpRequest("GET", "/");
        req.app = Some(app)
        req.ip = "10.0.0.9"
        req.headers["x-forwarded-for"] = "10.0.0.1, 10.0.0.2"
        @Assert(req.ips().size == 0)
        @Assert(req.clientIp() == "10.0.0.9")
    }

    // 信任代理时,ips() 按顺序解析 X-Forwarded-For,clientIp() 取链首。
    @TestCase
    func testIpsWithTrust(): Unit {
        let app = wen()
        app.trustProxy = true
        let req = HttpRequest("GET", "/");
        req.app = Some(app)
        req.ip = "10.0.0.9"
        req.headers["x-forwarded-for"] = "10.0.0.1, 10.0.0.2"
        let chain = req.ips()
        @Assert(chain.size == 2)
        @Assert(chain[0] == "10.0.0.1")
        @Assert(chain[1] == "10.0.0.2")
        @Assert(req.clientIp() == "10.0.0.1")
    }

    // 信任代理时,hostname 采用 X-Forwarded-Host。
    @TestCase
    func testHostnameForwarded(): Unit {
        let app = wen()
        app.trustProxy = true
        let req = HttpRequest("GET", "/");
        req.app = Some(app)
        req.headers["host"] = "internal:8080"
        req.headers["x-forwarded-host"] = "public.example.com"
        let h = match (req.hostname()) {
            case Some(v) => v;
            case None => "?"
        }
        @Assert(h == "public.example.com")
    }

    // subdomains:默认 offset=2,去掉末尾「主域+顶级域」,其余由近及远返回。
    @TestCase
    func testSubdomains(): Unit {
        let req = HttpRequest("GET", "/")
        req.headers["host"] = "tobi.ferrets.example.com"
        let subs = req.subdomains()
        @Assert(subs.size == 2)
        @Assert(subs[0] == "ferrets")
        @Assert(subs[1] == "tobi")
    }

    // 纯 IP 主机名不拆子域名。
    @TestCase
    func testSubdomainsIpEmpty(): Unit {
        let req = HttpRequest("GET", "/")
        req.headers["host"] = "127.0.0.1"
        @Assert(req.subdomains().size == 0)
    }

    // 应用设置 "subdomain offset" 可覆盖默认的 2。
    @TestCase
    func testSubdomainOffsetSetting(): Unit {
        let app = wen()
        app.set("subdomain offset", "3")
        let req = HttpRequest("GET", "/");
        req.app = Some(app)
        req.headers["host"] = "a.b.example.com"
        // 去掉末尾 3 段(b.example.com 中的 3 段?)—— a.b.example.com 共 4 段,
        // 扣除 3 段后只剩 "a"。
        let subs = req.subdomains()
        @Assert(subs.size == 1)
        @Assert(subs[0] == "a")
    }

    // xhr:X-Requested-With == XMLHttpRequest(大小写无关)。
    @TestCase
    func testXhr(): Unit {
        let req = HttpRequest("GET", "/")
        @Assert(!req.xhr())
        req.headers["x-requested-with"] = "XMLHttpRequest"
        @Assert(req.xhr())
    }
}
