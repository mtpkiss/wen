package wen

/*
 * Core function-type contracts shared by the whole framework.
 *
 * A `Next` advances the middleware chain to the following matching layer.
 * A `Middleware` is the universal unit of work: route handlers, plugins and
 * global middleware all share this shape, exactly like Express's
 * `(req, res, next)`.
 */
public type Next = () -> Unit

public type Middleware = (HttpRequest, HttpResponse, Next) -> Unit

// A terminal handler that does not need the `next` continuation.
public type Handler = (HttpRequest, HttpResponse) -> Unit

// An error-handling middleware, mirroring Express's `(err, req, res, next)`.
// It runs only while an exception is in flight; calling `next()` passes the
// same error on to the following error handler (or the default 500 if none).
public type ErrorHandler = (Exception, HttpRequest, HttpResponse, Next) -> Unit
