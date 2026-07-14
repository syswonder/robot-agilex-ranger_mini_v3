import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent


class RangerNavigationConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.params = yaml.safe_load((ROOT / "config" / "nav2_params.yaml").read_text())
        self.controller = self.params["controller_server"]["ros__parameters"]

    def test_terminal_latches_survive_replanning(self):
        follow = self.controller["FollowPath"]
        goal = self.controller["general_goal_checker"]
        self.assertEqual(follow["plugin"], "dwb_core::DWBLocalPlanner")
        self.assertIn("PersistentRotateToGoal", follow["critics"])
        self.assertNotIn("RotateToGoal", follow["critics"])
        self.assertEqual(goal["plugin"], "robonix_nav2_terminal::PersistentGoalChecker")
        self.assertEqual(goal["xy_enter_tolerance"], 0.30)
        self.assertEqual(goal["xy_exit_tolerance"], 0.45)
        self.assertEqual(
            follow["PersistentRotateToGoal.max_terminal_angular_velocity"], 0.30
        )
        self.assertEqual(follow["PersistentRotateToGoal.max_terminal_duration"], 15.0)

    def test_recovery_tree_does_not_command_physical_recovery(self):
        navigator = self.params["bt_navigator"]["ros__parameters"]
        self.assertEqual(navigator["default_bt_xml_filename"], "__ROBONIX_BT_XML__")
        self.assertEqual(
            navigator["default_nav_to_pose_bt_xml"], "__ROBONIX_BT_XML__"
        )
        tree = ET.parse(ROOT / "config" / "navigate.xml")
        root_recovery = tree.find(".//BehaviorTree/RecoveryNode")
        self.assertEqual(root_recovery.attrib["number_of_retries"], "1")
        self.assertEqual(tree.find(".//RateController").attrib["hz"], "5.0")
        self.assertIsNone(tree.find(".//Spin"))
        self.assertIsNone(tree.find(".//BackUp"))
        self.assertNotIn("path_topic", tree.find(".//FollowPath").attrib)

    def test_known_goals_limit_unknown_path_segments(self):
        planner = self.params["planner_server"]["ros__parameters"]
        self.assertEqual(
            planner["GridBased"]["plugin"],
            "robonix_nav2_terminal::GoalAwareNavfnPlanner",
        )
        self.assertFalse(planner["GridBased_known"]["allow_unknown"])
        self.assertTrue(planner["GridBased_unknown"]["allow_unknown"])
        self.assertEqual(planner["GridBased"]["max_unknown_ratio"], 0.05)
        self.assertEqual(planner["GridBased"]["max_unknown_length"], 0.75)
        self.assertEqual(planner["GridBased"]["max_unknown_run"], 0.40)

    def test_global_and_local_clearance_match(self):
        global_params = self.params["global_costmap"]["global_costmap"]["ros__parameters"]
        local_params = self.params["local_costmap"]["local_costmap"]["ros__parameters"]
        self.assertEqual(
            global_params["inflation_layer"]["inflation_radius"],
            local_params["inflation_layer"]["inflation_radius"],
        )


if __name__ == "__main__":
    unittest.main()
