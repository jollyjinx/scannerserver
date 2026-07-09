import importlib.util
import sys
import threading
import time
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_app_module():
    class FakeFlask:
        def __init__(self, *args, **kwargs):
            pass

        def get(self, *args, **kwargs):
            return lambda func: func

        def post(self, *args, **kwargs):
            return lambda func: func

        def run(self, *args, **kwargs):
            pass

    flask_stub = types.SimpleNamespace(
        Flask=FakeFlask,
        Response=object,
        redirect=lambda *args, **kwargs: None,
        render_template_string=lambda *args, **kwargs: "",
        request=types.SimpleNamespace(args={}, form={}),
        url_for=lambda *args, **kwargs: "",
    )
    pikepdf_stub = types.SimpleNamespace(PdfImage=object, open=lambda *args, **kwargs: None)
    pil_stub = types.ModuleType("PIL")
    pil_image_stub = types.SimpleNamespace(open=lambda *args, **kwargs: None)

    previous = {name: sys.modules.get(name) for name in ("flask", "pikepdf", "PIL", "PIL.Image")}
    sys.modules.update(
        {
            "flask": flask_stub,
            "pikepdf": pikepdf_stub,
            "PIL": pil_stub,
            "PIL.Image": pil_image_stub,
        }
    )
    spec = importlib.util.spec_from_file_location("scannerserver_app", ROOT / "app.py")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    finally:
        for name, value in previous.items():
            if value is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = value
    return module


class ButtonArmCoordinatorTests(unittest.TestCase):
    def test_start_returns_before_arm_function_finishes(self):
        app = load_app_module()
        release = threading.Event()
        calls = []

        def slow_arm():
            calls.append(time.monotonic())
            release.wait(timeout=2)
            return True

        coordinator = app.ButtonArmCoordinator(arm_func=slow_arm)

        started_at = time.monotonic()
        self.assertTrue(coordinator.start())
        self.assertLess(time.monotonic() - started_at, 0.2)
        self.assertFalse(coordinator.start())
        self.assertIsNone(coordinator.drain_result())

        release.set()
        deadline = time.monotonic() + 2
        result = None
        while time.monotonic() < deadline:
            result = coordinator.drain_result()
            if result is not None:
                break
            time.sleep(0.01)

        self.assertTrue(result)
        self.assertEqual(len(calls), 1)
        self.assertTrue(coordinator.start())


if __name__ == "__main__":
    unittest.main()
