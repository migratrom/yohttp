wrk.method = "POST"
wrk.path = "/api/echo"
wrk.headers["Content-Type"] = "application/octet-stream"
wrk.body = string.rep("x", 256 * 1024)
