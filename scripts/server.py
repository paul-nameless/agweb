# The selftest's page server: python's static server, threaded, with ?delay=ms to answer slowly.
import sys, time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        delay = parse_qs(urlparse(self.path).query).get("delay")
        if delay:
            time.sleep(int(delay[0]) / 1000)
        super().do_GET()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
