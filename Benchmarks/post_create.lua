wrk.method = "POST"
wrk.path = "/api/todos"
wrk.headers["Content-Type"] = "application/json"
wrk.body = [[{"title":"Learn YoHTTP","tags":["swift","nio","benchmark"]}]]
