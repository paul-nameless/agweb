# The selftest's page server: python's static server, threaded, with ?delay=ms to answer slowly, ?to=URL to redirect
# and ?challenge=1 for a page shaped like Cloudflare's challenge (its header, its widget's hidden input).
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
        if "challenge" in query:
            body = (b'<title>Just a moment...</title><h1>Performing security verification</h1>'
                    b'<div style="margin: 40px; width: 300px; height: 65px"><input type="hidden" id="cf-chl-widget-test_response"></div>')
            self.send_response(403)
            self.send_header("cf-mitigated", "challenge")
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
