package wen

import std.collection.*
import std.convert.*

/*
 * Minimal, zero-dependency JSON value type + parser + serializer.
 *
 * REPLACEMENT SEAM
 * ----------------
 * This single file is the only place the framework knows how JSON works. The
 * rest of Wen depends on just three things:
 *   - the `JsonValue` type (+ the `JsonObj` builder)
 *   - `parseJson(text): JsonValue`
 *   - `JsonValue.toJsonString(): String`
 * plus the thin wrappers `res.json(JsonValue)` and `req.json()`.
 *
 * To swap this for the official `stdx.encoding.json` later, reimplement THIS
 * file only: keep these signatures and delegate to stdx internally (an adapter
 * over stdx's JsonValue), or re-alias `JsonValue` to stdx's type and adjust the
 * handful of constructors/accessors. No call site in the framework changes.
 */

// Thrown when input is not well-formed JSON.
public class JsonException <: Exception {
    public init(msg: String) {
        super("JSON: ${msg}")
    }
}

// A JSON value. Objects keep their members in insertion order (an ordered list
// of pairs) so serialization is deterministic and round-trips predictably.
public enum JsonValue {
    | JsonNull
    | JsonBool(Bool)
    | JsonNumber(String)        // the numeric lexeme, preserved verbatim
    | JsonString(String)
    | JsonArray(ArrayList<JsonValue>)
    | JsonObject(ArrayList<(String, JsonValue)>)

    // ---- typed accessors (None when the kind does not match) ----------------

    public func asString(): ?String {
        match (this) {
            case JsonString(s) => Some(s)
            case _ => None
        }
    }

    public func asBool(): ?Bool {
        match (this) {
            case JsonBool(b) => Some(b)
            case _ => None
        }
    }

    public func asInt(): ?Int64 {
        match (this) {
            case JsonNumber(n) => try { Some(Int64.parse(n)) } catch (_: Exception) { None }
            case _ => None
        }
    }

    public func asFloat(): ?Float64 {
        match (this) {
            case JsonNumber(n) => try { Some(Float64.parse(n)) } catch (_: Exception) { None }
            case _ => None
        }
    }

    public func isNull(): Bool {
        match (this) {
            case JsonNull => true
            case _ => false
        }
    }

    // Object member by key (first match), or None.
    public func get(key: String): ?JsonValue {
        match (this) {
            case JsonObject(pairs) =>
                for ((k, v) in pairs) {
                    if (k == key) {
                        return Some(v)
                    }
                }
                return None
            case _ => return None
        }
    }

    // Array element by index, or None.
    public func at(i: Int64): ?JsonValue {
        match (this) {
            case JsonArray(items) =>
                if (i >= 0 && i < items.size) {
                    return Some(items[i])
                }
                return None
            case _ => return None
        }
    }

    // Element count for arrays/objects; 0 otherwise.
    public func size(): Int64 {
        match (this) {
            case JsonArray(items) => items.size
            case JsonObject(pairs) => pairs.size
            case _ => 0
        }
    }

    // Object keys in order (empty for non-objects).
    public func keys(): ArrayList<String> {
        let out = ArrayList<String>()
        match (this) {
            case JsonObject(pairs) => for ((k, _) in pairs) { out.add(k) }
            case _ => ()
        }
        return out
    }

    // ---- serialization ------------------------------------------------------

    public func toJsonString(): String {
        match (this) {
            case JsonNull => return "null"
            case JsonBool(b) => return if (b) { "true" } else { "false" }
            case JsonNumber(n) => return n
            case JsonString(s) => return "\"" + escapeJson(s) + "\""
            case JsonArray(items) =>
                var out = "["
                var first = true
                for (it in items) {
                    if (!first) {
                        out += ","
                    }
                    out += it.toJsonString()
                    first = false
                }
                return out + "]"
            case JsonObject(pairs) =>
                var out = "{"
                var first = true
                for ((k, v) in pairs) {
                    if (!first) {
                        out += ","
                    }
                    out += "\"" + escapeJson(k) + "\":" + v.toJsonString()
                    first = false
                }
                return out + "}"
        }
    }
}

// ---- builders -------------------------------------------------------------

public func jsonOf(v: String): JsonValue { return JsonString(v) }
public func jsonOf(v: Int64): JsonValue { return JsonNumber(v.toString()) }
public func jsonOf(v: Float64): JsonValue { return JsonNumber(v.toString()) }
public func jsonOf(v: Bool): JsonValue { return JsonBool(v) }
public func jsonNull(): JsonValue { return JsonNull }
public func jsonArray(items: ArrayList<JsonValue>): JsonValue { return JsonArray(items) }

// Ergonomic ordered object builder: JsonObj().put("id", 42).put("name", "a").build()
public class JsonObj {
    let pairs = ArrayList<(String, JsonValue)>()

    public init() {}

    public func put(key: String, value: JsonValue): JsonObj { pairs.add((key, value)); return this }
    public func put(key: String, value: String): JsonObj { pairs.add((key, JsonString(value))); return this }
    public func put(key: String, value: Int64): JsonObj { pairs.add((key, JsonNumber(value.toString()))); return this }
    public func put(key: String, value: Float64): JsonObj { pairs.add((key, JsonNumber(value.toString()))); return this }
    public func put(key: String, value: Bool): JsonObj { pairs.add((key, JsonBool(value))); return this }

    public func build(): JsonValue { return JsonObject(pairs) }
    public func toJsonString(): String { return build().toJsonString() }
}

// ---- public entry point ---------------------------------------------------

// Parse a JSON document. Throws JsonException on malformed input.
public func parseJson(text: String): JsonValue {
    return JsonParser(text).parseDocument()
}

// ---- escaping -------------------------------------------------------------

// Escape a string's mandatory JSON characters; valid UTF-8 bytes pass through.
func escapeJson(s: String): String {
    let out = ArrayList<UInt8>()
    for (b in s.toArray()) {
        if (b == UInt8(34)) {                  // "
            out.add(UInt8(92)); out.add(UInt8(34))
        } else if (b == UInt8(92)) {           // \
            out.add(UInt8(92)); out.add(UInt8(92))
        } else if (b == UInt8(8)) {            // backspace
            out.add(UInt8(92)); out.add(UInt8(98))
        } else if (b == UInt8(12)) {           // form feed
            out.add(UInt8(92)); out.add(UInt8(102))
        } else if (b == UInt8(10)) {           // \n
            out.add(UInt8(92)); out.add(UInt8(110))
        } else if (b == UInt8(13)) {           // \r
            out.add(UInt8(92)); out.add(UInt8(114))
        } else if (b == UInt8(9)) {            // \t
            out.add(UInt8(92)); out.add(UInt8(116))
        } else if (b < UInt8(32)) {            // other control char -> \u00XX
            out.add(UInt8(92)); out.add(UInt8(117)); out.add(UInt8(48)); out.add(UInt8(48))
            out.add(hexDigit(Int64(b) / 16))
            out.add(hexDigit(Int64(b) % 16))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

func hexDigit(v: Int64): UInt8 {
    if (v < 10) {
        return UInt8(48 + v)        // '0'..'9'
    }
    return UInt8(97 + v - 10)       // 'a'..'f'
}

// ---- parser ---------------------------------------------------------------

class JsonParser {
    let buf: Array<UInt8>
    var pos: Int64 = 0

    init(text: String) {
        this.buf = text.toArray()
    }

    func parseDocument(): JsonValue {
        skipWs()
        let v = parseValue()
        skipWs()
        if (pos < buf.size) {
            throw JsonException("trailing content at offset ${pos}")
        }
        return v
    }

    // Current byte as an Int64, or -1 at end of input.
    func peek(): Int64 {
        if (pos < buf.size) {
            return Int64(buf[pos])
        }
        return -1
    }

    func skipWs(): Unit {
        while (pos < buf.size) {
            let c = buf[pos]
            if (c == UInt8(32) || c == UInt8(9) || c == UInt8(10) || c == UInt8(13)) {
                pos += 1
            } else {
                break
            }
        }
    }

    func parseValue(): JsonValue {
        let c = peek()
        if (c < 0) {
            throw JsonException("unexpected end of input")
        }
        if (c == 123) { return parseObject() }       // {
        if (c == 91) { return parseArray() }         // [
        if (c == 34) { return JsonString(parseStringRaw()) } // "
        if (c == 116) { return parseLiteral("true", JsonBool(true)) }
        if (c == 102) { return parseLiteral("false", JsonBool(false)) }
        if (c == 110) { return parseLiteral("null", JsonNull) }
        if (c == 45 || (c >= 48 && c <= 57)) { return parseNumber() } // '-' or digit
        throw JsonException("unexpected character at offset ${pos}")
    }

    func parseLiteral(lit: String, value: JsonValue): JsonValue {
        let lb = lit.toArray()
        var i = 0
        while (i < lb.size) {
            if (pos + i >= buf.size || buf[pos + i] != lb[i]) {
                throw JsonException("invalid literal at offset ${pos}")
            }
            i += 1
        }
        pos += lb.size
        return value
    }

    func parseNumber(): JsonValue {
        let start = pos
        if (peek() == 45) {                  // -
            pos += 1
        }
        while (pos < buf.size && isDigit(buf[pos])) { pos += 1 }
        if (pos < buf.size && buf[pos] == UInt8(46)) {        // .
            pos += 1
            while (pos < buf.size && isDigit(buf[pos])) { pos += 1 }
        }
        if (pos < buf.size && (buf[pos] == UInt8(101) || buf[pos] == UInt8(69))) {  // e / E
            pos += 1
            if (pos < buf.size && (buf[pos] == UInt8(43) || buf[pos] == UInt8(45))) { pos += 1 }
            while (pos < buf.size && isDigit(buf[pos])) { pos += 1 }
        }
        let lex = String.fromUtf8(sliceBytes(buf, start, pos))
        if (lex.isEmpty() || lex == "-") {
            throw JsonException("invalid number at offset ${start}")
        }
        return JsonNumber(lex)
    }

    // Parse a string literal (current byte must be the opening quote).
    func parseStringRaw(): String {
        pos += 1                              // opening "
        let out = ArrayList<UInt8>()
        while (true) {
            if (pos >= buf.size) {
                throw JsonException("unterminated string")
            }
            let c = buf[pos]
            if (c == UInt8(34)) {             // closing "
                pos += 1
                break
            }
            if (c == UInt8(92)) {             // escape
                pos += 1
                if (pos >= buf.size) {
                    throw JsonException("bad escape")
                }
                let e = buf[pos]
                if (e == UInt8(34)) { out.add(UInt8(34)); pos += 1 }
                else if (e == UInt8(92)) { out.add(UInt8(92)); pos += 1 }
                else if (e == UInt8(47)) { out.add(UInt8(47)); pos += 1 }   // /
                else if (e == UInt8(98)) { out.add(UInt8(8)); pos += 1 }    // b
                else if (e == UInt8(102)) { out.add(UInt8(12)); pos += 1 }  // f
                else if (e == UInt8(110)) { out.add(UInt8(10)); pos += 1 }  // n
                else if (e == UInt8(114)) { out.add(UInt8(13)); pos += 1 }  // r
                else if (e == UInt8(116)) { out.add(UInt8(9)); pos += 1 }   // t
                else if (e == UInt8(117)) { pos += 1; appendUnicodeEscape(out) } // u
                else { throw JsonException("invalid escape at offset ${pos}") }
            } else {
                out.add(c)
                pos += 1
            }
        }
        return String.fromUtf8(out.toArray())
    }

    // After '\u', read 4 hex digits, resolve surrogate pairs, emit UTF-8 bytes.
    func appendUnicodeEscape(out: ArrayList<UInt8>): Unit {
        var code = readHex4()
        if (code >= 0xD800 && code <= 0xDBFF) {              // high surrogate
            if (pos + 1 < buf.size && buf[pos] == UInt8(92) && buf[pos + 1] == UInt8(117)) {
                pos += 2
                let low = readHex4()
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    code = 0x10000 + ((code - 0xD800) * 0x400) + (low - 0xDC00)
                } else {
                    code = 0xFFFD
                }
            } else {
                code = 0xFFFD
            }
        }
        encodeUtf8(code, out)
    }

    func readHex4(): Int64 {
        var v = 0
        var i = 0
        while (i < 4) {
            if (pos >= buf.size) {
                throw JsonException("bad unicode escape")
            }
            v = v * 16 + hexVal(buf[pos])
            pos += 1
            i += 1
        }
        return v
    }

    func parseObject(): JsonValue {
        pos += 1                              // {
        let pairs = ArrayList<(String, JsonValue)>()
        skipWs()
        if (peek() == 125) {                  // }
            pos += 1
            return JsonObject(pairs)
        }
        while (true) {
            skipWs()
            if (peek() != 34) {
                throw JsonException("expected string key at offset ${pos}")
            }
            let key = parseStringRaw()
            skipWs()
            if (peek() != 58) {               // :
                throw JsonException("expected ':' at offset ${pos}")
            }
            pos += 1
            skipWs()
            pairs.add((key, parseValue()))
            skipWs()
            let c = peek()
            if (c == 44) { pos += 1; continue }    // ,
            if (c == 125) { pos += 1; break }      // }
            throw JsonException("expected ',' or '}' at offset ${pos}")
        }
        return JsonObject(pairs)
    }

    func parseArray(): JsonValue {
        pos += 1                              // [
        let items = ArrayList<JsonValue>()
        skipWs()
        if (peek() == 93) {                   // ]
            pos += 1
            return JsonArray(items)
        }
        while (true) {
            skipWs()
            items.add(parseValue())
            skipWs()
            let c = peek()
            if (c == 44) { pos += 1; continue }    // ,
            if (c == 93) { pos += 1; break }       // ]
            throw JsonException("expected ',' or ']' at offset ${pos}")
        }
        return JsonArray(items)
    }
}

func isDigit(b: UInt8): Bool {
    return b >= UInt8(48) && b <= UInt8(57)
}

// Copy buf[start..end) into a fresh Array<UInt8>.
func sliceBytes(buf: Array<UInt8>, start: Int64, end: Int64): Array<UInt8> {
    if (end <= start) {
        return Array<UInt8>()
    }
    let out = Array<UInt8>(end - start, repeat: 0)
    var i = start
    while (i < end) {
        out[i - start] = buf[i]
        i += 1
    }
    return out
}

// Encode a Unicode code point as UTF-8 bytes.
func encodeUtf8(cp: Int64, out: ArrayList<UInt8>): Unit {
    if (cp < 0x80) {
        out.add(UInt8(cp))
    } else if (cp < 0x800) {
        out.add(UInt8(0xC0 | (cp >> 6)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    } else if (cp < 0x10000) {
        out.add(UInt8(0xE0 | (cp >> 12)))
        out.add(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    } else {
        out.add(UInt8(0xF0 | (cp >> 18)))
        out.add(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.add(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    }
}
