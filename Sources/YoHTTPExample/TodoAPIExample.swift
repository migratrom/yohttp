import Foundation
import YoHTTP

//
// Try it with:
//   curl http://127.0.0.1:9090/api/todos
//   curl -X POST http://127.0.0.1:9090/api/todos -H 'Content-Type: application/json' -d '{"title":"Learn YoHTTP","tags":["swift"]}'
//   curl -X PATCH http://127.0.0.1:9090/api/todos/<id> -H 'Content-Type: application/json' -d '{"completed":true}'

struct Todo: Codable, Sendable {
    let id: UUID
    var title: String
    var completed: Bool
    var tags: [String]
    let createdAt: Date
    var updatedAt: Date
}

struct CreateTodo: Decodable, Sendable {
    let title: String
    let completed: Bool?
    let tags: [String]?
}

struct ReplaceTodo: Decodable, Sendable {
    let title: String
    let completed: Bool
    let tags: [String]
}

struct UpdateTodo: Decodable, Sendable {
    let title: String?
    let completed: Bool?
    let tags: [String]?
}

struct ErrorMessage: Encodable, Sendable {
    let error: String
}

actor TodoStore {
    private var todos: [UUID: Todo] = {
        let now = Date()
        let first = Todo(
            id: UUID(), title: "Read the YoHTTP README", completed: false,
            tags: ["docs"], createdAt: now, updatedAt: now
        )
        let second = Todo(
            id: UUID(), title: "Ship an in-memory REST API", completed: true,
            tags: ["example", "swift"], createdAt: now, updatedAt: now
        )
        return [first.id: first, second.id: second]
    }()

    func list(completed: Bool?, search: String?) -> [Todo] {
        todos.values
            .filter { completed == nil || $0.completed == completed }
            .filter { todo in
                guard let search else { return true }
                return todo.title.localizedCaseInsensitiveContains(search)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func get(_ id: UUID) -> Todo? { todos[id] }

    func create(_ input: CreateTodo) -> Todo {
        let now = Date()
        let todo = Todo(
            id: UUID(), title: input.title, completed: input.completed ?? false,
            tags: input.tags ?? [], createdAt: now, updatedAt: now
        )
        todos[todo.id] = todo
        return todo
    }

    func replace(_ id: UUID, with input: ReplaceTodo) -> Todo? {
        guard let existing = todos[id] else { return nil }
        let todo = Todo(
            id: id, title: input.title, completed: input.completed, tags: input.tags,
            createdAt: existing.createdAt, updatedAt: Date()
        )
        todos[id] = todo
        return todo
    }

    func update(_ id: UUID, with input: UpdateTodo) -> Todo? {
        guard var todo = todos[id] else { return nil }
        if let title = input.title { todo.title = title }
        if let completed = input.completed { todo.completed = completed }
        if let tags = input.tags { todo.tags = tags }
        todo.updatedAt = Date()
        todos[id] = todo
        return todo
    }

    func delete(_ id: UUID) -> Bool { todos.removeValue(forKey: id) != nil }
}

enum API {
    static let todos = TodoStore()

    static func json<Value: Encodable>(
        _ value: Value,
        status: Status = .ok,
        headers: Headers = .init()
    ) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try .json(value, status: status, headers: headers, encoder: encoder)
    }

    static func error(_ status: Status, _ message: String) throws -> Response {
        try json(ErrorMessage(error: message), status: status)
    }

    static func decodeJSON<Value: Decodable>(_ type: Value.Type, from request: Request) async throws -> Value {
        guard request.header("Content-Type")?.lowercased().hasPrefix(MediaType.json.rawValue) == true else {
            throw Abort(.unsupportedMediaType, body: "Send a Content-Type: application/json header")
        }
        do {
            return try await request.decode(type)
        } catch {
            throw Abort(.badRequest, body: "Request body must be valid JSON")
        }
    }

    static func validTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@Route(.GET, "/health")
struct Health {
    func handle(_ request: Request) async throws -> Response {
        try API.json(["status": "ok"])
    }
}

// GET /api/todos?completed=true&search=swift
@Route(.GET, "/todos")
struct ListTodos {
    @QueryParam("completed") let completed: Bool
    @QueryParam("search") let search: String?

    func handle(_ request: Request) async throws -> Response {
        let todos = await API.todos.list(completed: completed, search: search)
        return try API.json(todos, headers: ["X-Total-Count": String(todos.count)])
    }
}

// POST /api/todos with { "title": "...", "completed": false, "tags": ["..."] }
@Route(.POST, "/todos")
struct CreateTodoEndpoint {
    func handle(_ request: Request) async throws -> Response {
        var input = try await API.decodeJSON(CreateTodo.self, from: request)
        guard let title = API.validTitle(input.title) else {
            return try API.error(.unprocessableContent, "'title' cannot be blank")
        }
        input = CreateTodo(title: title, completed: input.completed, tags: input.tags)
        let todo = await API.todos.create(input)
        return try API.json(todo, status: .created, headers: ["Location": "/api/todos/\(todo.id)"])
    }
}

@Route(.GET, "/todos/{id}")
struct GetTodo {
    @PathParam("id") let id: UUID

    func handle(_ request: Request) async throws -> Response {
        guard let todo = await API.todos.get(id) else {
            return try API.error(.notFound, "Todo \(id) was not found")
        }
        return try API.json(todo)
    }
}

// PUT replaces the complete resource.
@Route(.PUT, "/todos/{id}")
struct ReplaceTodoEndpoint {
    @PathParam("id") let id: UUID

    func handle(_ request: Request) async throws -> Response {
        var input = try await API.decodeJSON(ReplaceTodo.self, from: request)
        guard let title = API.validTitle(input.title) else {
            return try API.error(.unprocessableContent, "'title' cannot be blank")
        }
        input = ReplaceTodo(title: title, completed: input.completed, tags: input.tags)
        guard let todo = await API.todos.replace(id, with: input) else {
            return try API.error(.notFound, "Todo \(id) was not found")
        }
        return try API.json(todo)
    }
}

// PATCH changes only the supplied fields.
@Route(.PATCH, "/todos/{id}")
struct UpdateTodoEndpoint {
    @PathParam("id") let id: UUID

    func handle(_ request: Request) async throws -> Response {
        var input = try await API.decodeJSON(UpdateTodo.self, from: request)
        guard input.title != nil || input.completed != nil || input.tags != nil else {
            return try API.error(.unprocessableContent, "Supply at least one field to update")
        }
        if let title = input.title {
            guard let validTitle = API.validTitle(title) else {
                return try API.error(.unprocessableContent, "'title' cannot be blank")
            }
            input = UpdateTodo(title: validTitle, completed: input.completed, tags: input.tags)
        }
        guard let todo = await API.todos.update(id, with: input) else {
            return try API.error(.notFound, "Todo \(id) was not found")
        }
        return try API.json(todo)
    }
}

@Route(.DELETE, "/todos/{id}")
struct DeleteTodo {
    @PathParam("id") let id: UUID

    func handle(_ request: Request) async throws -> Response {
        guard await API.todos.delete(id) else {
            return try API.error(.notFound, "Todo \(id) was not found")
        }
        return Response(status: .noContent)
    }
}

@main
enum TodoAPIExample {
    static func main() async throws {
        let router = YoHTTPRouter()

        // Middleware is a natural place for request IDs, logging, auth, or CORS.
        router.middleware { request, next in
            var response = try await next(request)
            response.headers["X-Request-ID"] = UUID().uuidString
            print("\(request.method) \(request.path) -> \(response.status)")
            return response
        }

        router.register(Health.self)
        router.group("/api") { api in
            api.register(ListTodos.self)
            api.register(CreateTodoEndpoint.self)
            api.register(GetTodo.self)
            api.register(ReplaceTodoEndpoint.self)
            api.register(UpdateTodoEndpoint.self)
            api.register(DeleteTodo.self)
        }

        let server = YoHTTPServer()
        server.handler(router)
        print("Todo API listening on http://127.0.0.1:9090")
        print("Try GET /api/todos?completed=true, POST /api/todos, and OPTIONS /api/todos/<id>.")
        try await server.listen("127.0.0.1", 9090)
    }
}
