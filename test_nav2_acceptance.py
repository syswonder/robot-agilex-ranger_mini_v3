import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "nav2_acceptance", ROOT / "scripts" / "nav2_acceptance.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class RangerAcceptanceTest(unittest.TestCase):
    def test_nominal_terminal_run_passes(self):
        metrics = MODULE.TerminalMetrics(MODULE.GoalSpec("g", 0.0, 0.0, 1.0))
        metrics.update_pose(0.20, 0.0, 0.0, 10.0)
        metrics.update_cmd(0.0, 0.25)
        metrics.update_pose(0.22, 0.0, 0.8, 11.0)
        metrics.update_pose(0.21, 0.0, 1.0, 12.0)
        metrics.update_odom(0.0, 0.0)
        self.assertEqual(metrics.evaluate(True, 12.0), [])

    def test_rotation_loop_is_rejected(self):
        metrics = MODULE.TerminalMetrics(MODULE.GoalSpec("g", 0.0, 0.0, 0.2))
        metrics.update_pose(0.20, 0.0, 0.0, 10.0)
        for index in range(1, 9):
            metrics.update_pose(0.20, 0.0, index * 0.2, 10.0 + index)
        self.assertTrue(any("terminal rotation" in f for f in metrics.evaluate(True, 18.0)))

    def test_runtime_has_one_goal_send_site_and_no_retry_api(self):
        source = (ROOT / "scripts" / "nav2_acceptance.py").read_text()
        self.assertEqual(source.count("send_goal_async("), 1)
        self.assertNotIn("retry", source.lower())

    def test_plan_requires_five_goals(self):
        try:
            import yaml  # noqa: F401
        except ImportError:
            self.skipTest("PyYAML unavailable")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.yaml"
            path.write_text("goals:\n  - {name: only, x: 0, y: 0, yaw: 0}\n")
            with self.assertRaisesRegex(ValueError, "at least five"):
                MODULE.load_plan(path)


if __name__ == "__main__":
    unittest.main()
