import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent


def entries(doc, section):
    return {entry["name"]: entry for entry in doc.get(section, [])}


class DeployConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.full = yaml.safe_load((ROOT / "robonix_manifest.yaml").read_text())
        cls.no_arm = yaml.safe_load((ROOT / "robonix_manifest.no-arm.yaml").read_text())

    def test_catalog_metadata_is_complete(self):
        for doc in (self.full, self.no_arm):
            self.assertEqual(doc["catalog"]["license"], "Apache-2.0")
            self.assertTrue(doc["catalog"]["maintainers"])

    def test_vitals_is_enabled_for_full_and_no_arm_deployments(self):
        for doc in (self.full, self.no_arm):
            self.assertEqual(doc["system"]["vitals"]["listen"], "0.0.0.0:50093")

    def test_ros_middleware_uses_the_standard_environment_variable(self):
        for doc in (self.full, self.no_arm):
            self.assertEqual(doc["env"]["RMW_IMPLEMENTATION"], "rmw_zenoh_cpp")
            self.assertNotIn("ROBONIX_RMW_IMPLEMENTATION", doc["env"])

        for script_name in ("start.sh", "start_rviz2.sh"):
            script = (ROOT / script_name).read_text()
            self.assertIn("RMW_IMPLEMENTATION", script)
            self.assertNotIn("ROBONIX_RMW_IMPLEMENTATION", script)

        env_example = (ROOT / ".env.example").read_text()
        self.assertNotIn("ROBONIX_RMW_IMPLEMENTATION", env_example)
        self.assertNotIn("RMW_IMPLEMENTATION=", env_example)

    def test_target_selection_lives_in_package_manifests(self):
        redundant_env = {
            "ROBONIX_ZENOH_ROUTER",
            "ROBONIX_ZENOH_MODE",
            "RBNX_BUILD_TARGET",
            "ROBONIX_SCENE_FORCE",
            "ROBONIX_SCENE_PLATFORM",
            "ROBONIX_SCENE_ROS_DISTRO",
            "SCENE_NATIVE_PYTHON",
            "SCENE_WEB_PORT",
            "ROBONIX_MAPPING_FORCE",
            "ROBONIX_MAPPING_PLATFORM",
            "MAPPING_WEBUI_PORT",
            "ROBONIX_NAV2_FORCE",
            "ROBONIX_NAV2_PLATFORM",
        }
        for doc in (self.full, self.no_arm):
            self.assertFalse(redundant_env & set(doc["env"]))
            self.assertEqual(
                doc["system"]["scene"]["manifest"],
                "package_manifest.jetson-native.yaml",
            )
            self.assertEqual(doc["system"]["scene"]["web_port"], 50107)

            services = entries(doc, "service")
            self.assertEqual(
                services["mapping"]["manifest"],
                "package_manifest.jetson-native.yaml",
            )
            self.assertEqual(services["mapping"]["config"]["webui_port"], 8091)
            self.assertEqual(
                services["nav2"]["manifest"],
                "package_manifest.jetson-native.yaml",
            )
            self.assertEqual(
                services["speech"]["config"]["speech_backend"], "tencent"
            )

    def test_removed_or_redundant_fields_do_not_return(self):
        forbidden = {
            ("primitive", "mid360_lidar"): {"lidar_topic", "imu_topic", "livox_retries"},
            ("primitive", "mid360_imu"): {"imu_topic"},
            ("primitive", "realsense_camera"): {
                "camera_name", "rgb_profile", "align_depth", "spatial_filter",
                "temporal_filter", "hole_filling_filter", "enable_sync",
            },
            ("primitive", "ranger_chassis"): {
                "robot_model", "odom_topic_name", "odom_frame", "base_frame",
                "sentinel_timeout_s",
            },
            ("primitive", "audio_client_bridge"): {"transport"},
            ("service", "mapping"): {"platform", "rtabmap_profile", "sensors"},
            ("service", "nav2"): {"platform", "params_profile", "scan_deskewing"},
            ("skill", "explore"): {"explore_mode", "timeout_s"},
        }
        for doc in (self.full, self.no_arm):
            for (section, name), keys in forbidden.items():
                config = entries(doc, section).get(name, {}).get("config", {}) or {}
                self.assertFalse(keys & set(config), f"{section}.{name}: {keys & set(config)}")

    def test_no_arm_matches_shared_full_body_config(self):
        for section in ("primitive", "service", "skill"):
            full_entries = entries(self.full, section)
            for name, entry in entries(self.no_arm, section).items():
                self.assertEqual(entry, full_entries[name], f"{section}.{name}")

    def test_navigation_uses_deploy_owned_files(self):
        nav = entries(self.full, "service")["nav2"]["config"]
        self.assertEqual(nav["params_file"], "config/nav2_params.yaml")
        self.assertEqual(nav["bt_xml_file"], "config/navigate.xml")
        self.assertTrue(nav["scan_projection"]["enabled"])

    def test_mapping_uses_deploy_owned_file(self):
        mapping = entries(self.full, "service")["mapping"]["config"]
        self.assertEqual(mapping["params_file"], "config/rtabmap_params.yaml")
        self.assertNotIn("rtabmap_params", mapping)
        params = yaml.safe_load((ROOT / mapping["params_file"]).read_text())
        self.assertEqual(params["Grid/FootprintLength"], 0.84)
        self.assertEqual(params["Rtabmap/DetectionRate"], 5.0)


if __name__ == "__main__":
    unittest.main()
