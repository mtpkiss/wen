package wen

/*
 * HTTP method names. Routes are keyed by the uppercase string form so that
 * matching against a parsed request line stays trivial.
 */
public class HttpMethod {
    public static const GET: String = "GET"
    public static const POST: String = "POST"
    public static const PUT: String = "PUT"
    public static const DELETE: String = "DELETE"
    public static const PATCH: String = "PATCH"
    public static const HEAD: String = "HEAD"
    public static const OPTIONS: String = "OPTIONS"
    public static const ALL: String = "*"
}
