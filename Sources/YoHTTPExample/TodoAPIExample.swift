import Foundation
import Synchronization
import YoHTTP

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
struct ErrorMessage: Encodable, Sendable { let error: String }

actor TodoStore {
	private var todos: [UUID: Todo] = {
		let now = Date()
		let first = Todo(
			id: UUID(), title: "Read the YoHTTP README", completed: false,
			tags: ["docs"], createdAt: now,
			updatedAt: now)
		let second = Todo(
			id: UUID(), title: "Ship an in-memory REST API", completed: true,
			tags: ["example", "swift"],
			createdAt: now, updatedAt: now)
		return [first.id: first, second.id: second]
	}()

	func list(completed: Bool?, search: String?) -> [Todo] {
		todos.values.filter { completed == nil || $0.completed == completed }
			.filter {
				search == nil || $0.title.localizedCaseInsensitiveContains(search!)
			}
			.sorted { $0.createdAt < $1.createdAt }
	}
	func get(_ id: UUID) -> Todo? { todos[id] }
	func create(_ input: CreateTodo) -> Todo {
		let now = Date()
		let todo = Todo(
			id: UUID(), title: input.title, completed: input.completed ?? false,
			tags: input.tags ?? [],
			createdAt: now, updatedAt: now)
		todos[todo.id] = todo
		return todo
	}
	func replace(_ id: UUID, with input: ReplaceTodo) -> Todo? {
		guard let existing = todos[id] else { return nil }
		let todo = Todo(
			id: id, title: input.title, completed: input.completed, tags: input.tags,
			createdAt: existing.createdAt, updatedAt: Date())
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
		_ value: Value, version: HTTPVersion, to response: ResponseWriter,
		status: HTTPResponseStatus = .ok, headers: HTTPHeaders = .init()
	) {
		do {
			let encoder = JSONEncoder()
			encoder.dateEncodingStrategy = .iso8601
			var head = HTTPResponseHead(version: version, status: status, headers: headers)
			head.headers.replaceOrAdd(
				name: "Content-Type", value: "application/json")
			response.head.initialize(head)
			response.write(ByteBuffer(bytes: try encoder.encode(value)))
			response.end()
		} catch {
			response.head.initialize(
				HTTPResponseHead(version: version, status: .internalServerError))
			response.write(ByteBuffer(string: "Internal Server Error"))
			response.end()
		}
	}

	static func error(
		_ status: HTTPResponseStatus, _ message: String, version: HTTPVersion,
		to response: ResponseWriter
	) {
		json(ErrorMessage(error: message), version: version, to: response, status: status)
	}

	static func decodeJSON<Value: Decodable & Sendable>(
		_ type: Value.Type, data: Data, contentType: String?
	) -> Result<Value, Abort> {
		guard contentType?.lowercased().hasPrefix("application/json") == true else {
			return .failure(
				Abort(
					.unsupportedMediaType,
					body: ByteBuffer(string: "Send a Content-Type: application/json header")))
		}
		do { return .success(try JSONDecoder().decode(type, from: data)) } catch {
			return .failure(
				Abort(.badRequest, body: ByteBuffer(string: "Request body must be valid JSON")))
		}
	}

	static func validTitle(_ title: String) -> String? {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}

/// Collects JSON only for endpoints that opt into it. The server itself never
/// buffers request bodies; production applications should enforce their own
/// endpoint-specific limit here when needed.
func receiveJSON<Input: Decodable & Sendable>(
	_ type: Input.Type, request: consuming Request,
	complete: @escaping @Sendable (Result<Input, Abort>) -> Void
) {
	let bytes = Mutex(Data())
	let contentType = request.head.headers.first(name: "content-type")
	request.body.stream().onChunk { chunk in
		bytes.withLock { $0.append(contentsOf: chunk.readableBytesView) }
	}.onEnd {
		complete(
			API.decodeJSON(
				type, data: bytes.withLock { $0 },
				contentType: contentType)
		)
	}.onError { _ in
		complete(
			.failure(Abort(.badRequest, body: ByteBuffer(string: "Request body could not be read"))))
	}
}

@Route(.GET, "/health")
struct Health {
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		response.head.initialize(HTTPResponseHead(version: request.head.version, status: .ok))
		response.write(ByteBuffer(string: "ok"))
		response.end()
	}
}

@Route(.GET, "/todos")
struct ListTodos {
	@QueryParam("completed") let completed: Bool
	@QueryParam("search") let search: String?

	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		let version = request.head.version
		let writer = response.writer()
		Task {
			let todos = await API.todos.list(completed: completed, search: search)
			API.json(
				todos, version: version, to: writer,
				headers: ["X-Total-Count": String(todos.count)]
			)
		}
	}
}

@Route(.POST, "/todos")
struct CreateTodoEndpoint {
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		let version = request.head.version
		let writer = response.writer()
		receiveJSON(CreateTodo.self, request: request) { result in
			Task {
				switch result {
				case .failure(let error):
					API.error(
						error.status,
						String(decoding: error.body.readableBytesView, as: UTF8.self),
						version: version, to: writer)
				case .success(var input):
					guard let title = API.validTitle(input.title) else {
						return API.error(
							.unprocessableEntity,
							"'title' cannot be blank", version: version, to: writer)
					}
					input = CreateTodo(
						title: title, completed: input.completed,
						tags: input.tags)
					let todo = await API.todos.create(input)
					API.json(
						todo, version: version, to: writer, status: .created,
						headers: ["Location": "/api/todos/\(todo.id)"])
				}
			}
		}
	}
}

@Route(.GET, "/todos/{id}")
struct GetTodo {
	@PathParam("id") let id: UUID
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		let version = request.head.version
		let writer = response.writer()
		Task {
			guard let todo = await API.todos.get(id) else {
				return API.error(
					.notFound, "Todo \(id) was not found", version: version, to: writer)
			}
			API.json(todo, version: version, to: writer)
		}
	}
}

@Route(.PUT, "/todos/{id}")
struct ReplaceTodoEndpoint {
	@PathParam("id") let id: UUID
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		let version = request.head.version
		let writer = response.writer()
		receiveJSON(ReplaceTodo.self, request: request) { result in
			Task {
				switch result {
				case .failure(let error):
					API.error(
						error.status,
						String(decoding: error.body.readableBytesView, as: UTF8.self),
						version: version, to: writer)
				case .success(var input):
					guard let title = API.validTitle(input.title) else {
						return API.error(
							.unprocessableEntity,
							"'title' cannot be blank", version: version, to: writer)
					}
					input = ReplaceTodo(
						title: title, completed: input.completed,
						tags: input.tags)
					guard let todo = await API.todos.replace(id, with: input)
					else {
						return API.error(
							.notFound, "Todo \(id) was not found",
							version: version, to: writer)
					}
					API.json(todo, version: version, to: writer)
				}
			}
		}
	}
}

@Route(.PATCH, "/todos/{id}")
struct UpdateTodoEndpoint {
	@PathParam("id") let id: UUID
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		let version = request.head.version
		let writer = response.writer()
		receiveJSON(UpdateTodo.self, request: request) { result in
			Task {
				switch result {
				case .failure(let error):
					API.error(
						error.status,
						String(decoding: error.body.readableBytesView, as: UTF8.self),
						version: version, to: writer)
				case .success(var input):
					guard
						input.title != nil || input.completed != nil
							|| input.tags != nil
					else {
						return API.error(
							.unprocessableEntity,
							"Supply at least one field to update",
							version: version, to: writer)
					}
					if let title = input.title {
						guard let title = API.validTitle(title) else {
							return API.error(
								.unprocessableEntity,
								"'title' cannot be blank",
								version: version, to: writer)
						}
						input = UpdateTodo(
							title: title, completed: input.completed,
							tags: input.tags)
					}
					guard let todo = await API.todos.update(id, with: input)
					else {
						return API.error(
							.notFound, "Todo \(id) was not found",
							version: version, to: writer)
					}
					API.json(todo, version: version, to: writer)
				}
			}
		}
	}
}

@Route(.DELETE, "/todos/{id}")
struct DeleteTodo {
	@PathParam("id") let id: UUID
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		let version = request.head.version
		let writer = response.writer()
		Task {
			guard await API.todos.delete(id) else {
				return API.error(
					.notFound, "Todo \(id) was not found", version: version, to: writer)
			}
			writer.head.initialize(HTTPResponseHead(version: version, status: .noContent))
			writer.end()
		}
	}
}

@Route(.POST, "/echo")
struct Echo {
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		let writer = response.writer()
		writer.head.initialize(HTTPResponseHead(version: request.head.version, status: .ok))
		request.body.stream().onChunk { writer.write($0) }.onEnd { writer.end() }
	}
}

@main
enum TodoAPIExample {
	static func main() async throws {
		let router = YoHTTPRouter()
		router.middleware { request, response, next in
			response.head.modify { $0.headers.add(name: "X-Request-ID", value: UUID().uuidString) }
			print("\(request.head.method) \(request.head.uri)")
			try next(request, response)
		}
		router.register(Health.self)
		router.group("/api") { api in
			api.register(ListTodos.self)
			api.register(CreateTodoEndpoint.self)
			api.register(GetTodo.self)
			api.register(ReplaceTodoEndpoint.self)
			api.register(UpdateTodoEndpoint.self)
			api.register(DeleteTodo.self)
			api.register(Echo.self)
		}
		router.registrationLocked()
		let server = YoHTTPServer()
		server.handler(router)
		print("Todo API listening on http://127.0.0.1:9090")
		print(
			"Try GET /api/todos, POST /api/todos, PATCH /api/todos/<id>, or POST /api/echo."
		)
		try await server.listen("127.0.0.1", 9090)
	}
}
