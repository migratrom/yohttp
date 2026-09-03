import YoHTTP

let router = YoHTTPRouter()

router.path("/users", handlers: .init(
    GET: { _ in
        Response.text("users")
    },
    POST: { _ in
        Response(status: .created)
    }
))

let server = YoHTTPServer()
server.handler(router)
try await server.listen("127.0.0.1", 9090)
