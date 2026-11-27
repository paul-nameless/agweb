# The selftest's page server: python's static server, threaded, with ?delay=ms to answer slowly, ?to=URL to redirect
# and ?challenge=1 for a page shaped like Cloudflare's challenge (its header, its widget's hidden input), ?basic=USER:PASS
# for a page behind a Basic login (each wrong try a line in auth.log), ?bearer=1 for a 401 asking for a token. A
# POST to /order gets a "Posted" page and a line in posts.log, so a test can see a form sent twice; any other POST
# gets 501, as from python's static server. ?attach=NAME sends the file as an attachment named NAME.
import base64, sys, time
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
        if "basic" in query or "bearer" in query:
            sent = self.headers.get("Authorization")
            if "basic" not in query or sent != "Basic " + base64.b64encode(query["basic"][0].encode()).decode():
                if sent:
                    with open("auth.log", "a") as log:
                        log.write(sent + "\n")
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="agweb"' if "basic" in query else 'Bearer realm="api"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        self.attach = query.get("attach", [None])[0]
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

    def end_headers(self):
        if getattr(self, "attach", None):
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % self.attach)
        super().end_headers()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not self.path.startswith("/order"):
            self.send_error(501, "Unsupported method (%r)" % self.command)
            return
        with open("posts.log", "a") as log:
            log.write(self.path + "\n")
        body = b"<title>Posted</title><p>posted"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
