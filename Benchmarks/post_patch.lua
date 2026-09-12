wrk.method = "PATCH"
wrk.path = "/api/todos/00000000-0000-0000-0000-000000000001"
wrk.headers["Content-Type"] = "application/json"
wrk.body = [[{"completed":true}]]
