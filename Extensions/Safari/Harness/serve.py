#!/usr/bin/env python3
"""Drive the Safari extension's content script from any browser.

Serves the harness page and the extension files, and proxies the two things
the extension talks to: Lumi's page bridge (/bridge → 127.0.0.1:47121, with
Origin stripped — the same shape of request the appex relay sends) and
Google (/google → translate.googleapis.com, to sidestep CORS).

    python3 Extensions/Safari/Harness/serve.py
    open 'http://127.0.0.1:8765/?engine=online&style=pane'   # content script
    open 'http://127.0.0.1:8765/popup.html?active=1'          # popup; page=none for a blocked tab
    open 'http://127.0.0.1:8765/site?url=https://en.wikipedia.org/wiki/Transformer_(deep_learning)'
"""
import http.server, os, re, urllib.parse, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
EXT = os.path.join(HERE, '..', 'WebExtension')
ORIGIN = 'http://127.0.0.1:8765'
UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15'
UPSTREAM = {'/bridge': 'http://127.0.0.1:47121', '/google': 'https://translate.googleapis.com'}


class Handler(http.server.SimpleHTTPRequestHandler):
    # The files change under the browser on every edit; a heuristic cache
    # once served a stale background.js and made a fixed bug look unfixed.
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def translate_path(self, path):
        if path.startswith('/ext/'):
            return os.path.join(EXT, path[len('/ext/'):].split('?')[0])
        return os.path.join(HERE, path.lstrip('/').split('?')[0] or 'index.html')

    def proxy(self):
        for prefix, upstream in UPSTREAM.items():
            if self.path.startswith(prefix + '/'):
                break
        else:
            return False
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else None
        request = urllib.request.Request(upstream + self.path[len(prefix):], data=body, method=self.command)
        for name in ('Content-Type', 'X-Lumi-Client'):
            if self.headers.get(name):
                request.add_header(name, self.headers[name])
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                status, payload, kind = response.status, response.read(), response.headers.get('Content-Type')
        except urllib.error.HTTPError as error:
            status, payload, kind = error.code, error.read(), error.headers.get('Content-Type')
        except OSError as error:
            self.send_error(502, str(error))
            return True
        self.send_response(status)
        self.send_header('Content-Type', kind or 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        return True

    def do_GET(self):
        if self.path.split('?')[0] == '/popup.html':
            return self.popup()
        if self.path.startswith('/site?'):
            return self.site()
        if not self.proxy():
            super().do_GET()

    def site(self):
        """A live page with the extension injected, as Safari would inject it.

        The page is fetched here and re-served from this origin, which is the
        only way to run the scripts on sites whose CSP forbids both loading
        them and reaching Lumi (Wikipedia, GitHub, MDN). The site's own HTML
        and CSS are untouched; <base> keeps its relative links pointing home.
        A real content script is not subject to page CSP, so removing it here
        changes nothing the extension would see.
        """
        url = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)['url'][0]
        request = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.9'})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                final = response.geturl()
                charset = response.headers.get_content_charset() or 'utf-8'
                page = response.read().decode(charset, 'replace')
        except (urllib.error.URLError, OSError) as error:
            self.send_error(502, str(error))
            return
        page = re.sub(r'<meta[^>]+http-equiv=["\']?content-security-policy[^>]*>', '', page, flags=re.I)
        page = re.sub(r'<base\b[^>]*>', '', page, flags=re.I)
        head = (f'<base href="{final}">'
                f'<script src="{ORIGIN}/shim.js"></script>'
                f'<link rel="stylesheet" href="{ORIGIN}/ext/content.css">')
        tail = (f'<script type="module" src="{ORIGIN}/ext/background.js"></script>'
                f'<script src="{ORIGIN}/ext/content.js" defer></script>')
        page, found = re.subn(r'<head\b[^>]*>', lambda m: m.group(0) + head, page, count=1, flags=re.I)
        if not found:
            page = head + page
        page, found = re.subn(r'</body>', tail + '</body>', page, count=1, flags=re.I)
        if not found:
            page += tail
        payload = page.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def popup(self):
        """The real popup.html with the shim spliced in, built per request so
        it can never drift from the file that ships."""
        with open(os.path.join(EXT, 'popup.html'), encoding='utf-8') as f:
            page = f.read()
        with open(os.path.join(HERE, 'popup-shim.html'), encoding='utf-8') as f:
            shim = f.read()
        page = (page.replace('href="popup.css"', 'href="/ext/popup.css"')
                    .replace('src="icons/', 'src="/ext/icons/')
                    .replace('<script src="popup.js"></script>',
                             shim + '<script type="module" src="/ext/popup.js"></script>'))
        payload = page.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if not self.proxy():
            self.send_error(404)

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    http.server.ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('PORT', 8765))), Handler).serve_forever()
