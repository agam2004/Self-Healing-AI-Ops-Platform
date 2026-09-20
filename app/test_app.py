import json
import threading
import unittest
import urllib.request
from http.server import HTTPServer

from app import Handler


class AppTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.thread.join()

    def _get(self, path: str):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as resp:
            return resp.status, json.loads(resp.read())

    def test_health_returns_ok(self) -> None:
        status, body = self._get("/health")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"status": "ok"})

    def test_root_returns_service_info(self) -> None:
        status, body = self._get("/")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "aiops-app")

    def test_unknown_path_still_responds(self) -> None:
        # The handler has no 404 branch today — document that explicitly
        # rather than let CI silently mask a routing regression later.
        status, body = self._get("/does-not-exist")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "aiops-app")


if __name__ == "__main__":
    unittest.main()
