# The selftest's page server: python's static server, threaded, with ?delay=ms to answer slowly and ?to=URL to redirect.
import sys, time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        if "delay" in query:
            time.sleep(int(query["delay"][0]) / 1000)
        if "to" in query:
            self.send_response(302)
            self.send_header("Location", query["to"][0])
            self.end_headers()
            return
        super().do_GET()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
