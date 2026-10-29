import json
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

import server as app


class SecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = app.BoundedHTTPServer(('127.0.0.1', 0), app.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = 'http://127.0.0.1:' + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def fetch(self, path, headers=None):
        try:
            return urllib.request.urlopen(urllib.request.Request(self.url + path, headers=headers or {}), timeout=3)
        except urllib.error.HTTPError as exc:
            return exc

    def test_time_formats_and_oversized_input(self):
        for text, expected in [('1:30', 90), ('1h 32m', 92), ('2h', 120), ('105', 105)]:
            self.assertEqual(app.parse_time_limit(text), expected)
        with self.assertRaises(ValueError):
            app.parse_time_limit('9' * 65)

    def test_success_and_headers(self):
        with patch.object(app, 'make_payload', return_value={'movies': []}):
            with self.fetch('/api/movies?time=90') as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(json.load(response), {'movies': []})
                self.assertEqual(response.headers['X-Content-Type-Options'], 'nosniff')
                self.assertEqual(response.headers['Cache-Control'], 'no-store')

    def test_cross_site_request_blocked(self):
        with self.fetch('/api/movies', {'Sec-Fetch-Site': 'cross-site'}) as response:
            self.assertEqual(response.code, 403)

    def test_errors_do_not_disclose_secrets(self):
        with patch.object(app, 'make_payload', side_effect=RuntimeError('secret-token')):
            with self.fetch('/api/movies') as response:
                self.assertEqual(response.code, 502)
                self.assertNotIn('secret-token', response.read().decode())
        self.assertFalse(app.FETCH_LOCK.locked())

    def test_concurrent_fetch_rejected(self):
        with app.FETCH_LOCK:
            with self.fetch('/api/movies') as response:
                self.assertEqual(response.code, 503)

    def test_redirect_does_not_forward_token(self):
        request = urllib.request.Request('https://discover.provider.plex.tv/', headers={'X-Plex-Token': 'secret'})
        with self.assertRaises(urllib.error.URLError):
            app.NoRedirect().redirect_request(request, None, 302, '', {}, 'https://attacker.example/')

    def test_response_size_limit(self):
        class Response:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, size):
                return b'x' * size
        with patch.object(urllib.request.OpenerDirector, 'open', return_value=Response()):
            with self.assertRaises(RuntimeError):
                app.http_get('https://discover.provider.plex.tv/')


if __name__ == '__main__':
    unittest.main()
