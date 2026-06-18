package wen

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 测试可扩展的 MIME 类型映射:内置兜底不变、app.mime / registerMimeType 注册与覆盖、
 * 以及 contentTypeFor 复用同一张用户注册表。
 *
 * 注意:MIME 注册表是进程级全局状态,测试间共享。为避免相互污染(尤其不破坏其它
 * 测试对 .png/.css 等内置类型的断言),本文件一律使用 "zz" 前缀的私有扩展名,
 * 既不与内置表、也不与其它测试冲突。
 */
@Test
class MimeTest {
    // 内置兜底:未注册时,常见扩展名与未知扩展名的推断都保持原有行为。
    @TestCase
    func testBuiltinUnchanged(): Unit {
        @Assert(mimeFor("a.png") == "image/png")
        @Assert(mimeFor("style.css") == "text/css")
        @Assert(mimeFor("app.js") == "application/javascript")
        @Assert(mimeFor("Makefile") == "application/octet-stream")
        @Assert(mimeFor("data.zzunknown") == "application/octet-stream")
    }

    // 常见扩展名都内置:图片 / 字体 / 音视频 / 文档 / 归档等无需注册即可识别。
    @TestCase
    func testBuiltinCommonTypes(): Unit {
        @Assert(mimeFor("photo.webp") == "image/webp")
        @Assert(mimeFor("pic.avif") == "image/avif")
        @Assert(mimeFor("font.woff2") == "font/woff2")
        @Assert(mimeFor("font.ttf") == "font/ttf")
        @Assert(mimeFor("clip.mp4") == "video/mp4")
        @Assert(mimeFor("song.mp3") == "audio/mpeg")
        @Assert(mimeFor("doc.pdf") == "application/pdf")
        @Assert(mimeFor("bundle.zip") == "application/zip")
        @Assert(mimeFor("mod.wasm") == "application/wasm")
        @Assert(mimeFor("page.htm") == "text/html; charset=utf-8")
        @Assert(mimeFor("favicon.ico") == "image/x-icon")
        @Assert(mimeFor("data.xml") == "application/xml")
        // 大小写不敏感:大写扩展名同样命中内置表。
        @Assert(mimeFor("PHOTO.WEBP") == "image/webp")
    }

    // registerMimeType 新增一个内置表未覆盖的扩展名;大小写与前导点均不敏感。
    @TestCase
    func testRegisterNewExtension(): Unit {
        registerMimeType("zzwebp", "image/webp")
        @Assert(mimeFor("photo.zzwebp") == "image/webp")
        @Assert(mimeFor("PHOTO.ZZWEBP") == "image/webp")

        // 注册时带前导点,查询仍命中(键被规范化)。
        registerMimeType(".zzavif", "image/avif")
        @Assert(mimeFor("x.zzavif") == "image/avif")
    }

    // app.mime 是链式语法糖:连续注册多个、链上每个都生效。
    @TestCase
    func testAppMimeChainable(): Unit {
        let app = wen()
        app.mime("zzfmt1", "application/x-zzfmt1").mime("zzfmt2", "application/x-zzfmt2")
        @Assert(mimeFor("a.zzfmt1") == "application/x-zzfmt1")
        @Assert(mimeFor("b.zzfmt2") == "application/x-zzfmt2")
    }

    // 同一扩展名重复注册:后者覆盖前者。
    @TestCase
    func testReRegisterOverrides(): Unit {
        registerMimeType("zzdup", "application/x-first")
        registerMimeType("zzdup", "application/x-second")
        @Assert(mimeFor("a.zzdup") == "application/x-second")
    }

    // contentTypeFor 复用同一张用户注册表(使 res.type("zztype") 一致命中),
    // 同时保持:完整 MIME 原样、未知值回落 octet-stream、内置简写不变。
    @TestCase
    func testContentTypeForUsesRegistry(): Unit {
        registerMimeType("zztype", "application/x-zztype")
        @Assert(contentTypeFor("zztype") == "application/x-zztype")
        @Assert(contentTypeFor("application/pdf") == "application/pdf")
        @Assert(contentTypeFor("zznope") == "application/octet-stream")
        @Assert(contentTypeFor("json") == "application/json; charset=utf-8")
    }
}
