import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/v1/models":
            self.reply(200, {"object": "list", "data": [
                {"id": "fixture-model", "object": "model", "owned_by": "local"}
            ]})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path != "/v1/chat/completions":
            self.reply(404, {"error": "not found"})
            return
        self.reply(200, {
            "id": "chatcmpl-dbx-test", "object": "chat.completion",
            "model": request.get("model", "fixture-model"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "OK"}}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6},
        })


ThreadingHTTPServer(("0.0.0.0", 11434), Handler).serve_forever()
