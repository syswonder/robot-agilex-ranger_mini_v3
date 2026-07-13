# SPDX-License-Identifier: Apache-2.0
"""Read chassis motion from Soma's standard health snapshot."""
from __future__ import annotations

import logging
import time

log = logging.getLogger("greet_skill")


def snapshot_is_moving(snapshot, chassis_provider_id: str) -> bool:
    """Return true only for a fresh, valid moving metric from this chassis."""
    expected_component = f"body/chassis/{chassis_provider_id}"
    for metric in getattr(snapshot, "metrics", ()):
        if metric.name != "moving" or metric.component_id != expected_component:
            continue
        value = getattr(metric, "value", None)
        return bool(value is not None and value.quality == 0 and value.value >= 0.5)
    return False


class SomaMotionMonitor:
    """Small pull client used by the long-lived skill; it has no ROS dependency."""

    def __init__(self, endpoint: str, chassis_provider_id: str, timeout_s: float = 0.5):
        import grpc
        import robonix_contracts_pb2_grpc

        target = endpoint.removeprefix("http://").removeprefix("https://")
        self._channel = grpc.insecure_channel(target)
        self._stub = robonix_contracts_pb2_grpc.RobonixSystemSomaGetHealthStub(
            self._channel
        )
        self._provider_id = chassis_provider_id
        self._timeout_s = timeout_s
        self._last_warning_at = 0.0

    def is_moving(self) -> bool:
        from soma_pb2 import GetHealth_Request

        try:
            response = self._stub.GetHealth(
                GetHealth_Request(), timeout=self._timeout_s
            )
            return snapshot_is_moving(response.snapshot, self._provider_id)
        except Exception as exc:  # noqa: BLE001
            now = time.monotonic()
            if now - self._last_warning_at >= 10.0:
                log.warning("Soma motion state unavailable; greeting paused: %s", exc)
                self._last_warning_at = now
            return False

    def close(self) -> None:
        self._channel.close()
