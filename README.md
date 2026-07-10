# AgileX Ranger Mini v3

Robonix deployment for the SysWonder Ranger Mini v3: Jetson Orin, Livox
MID-360, Intel RealSense D435i, RTAB-Map, Scene, Nav2, and Explore.

The deployment uses native ROS 2 packages on Jetson. Zenoh RMW is the default;
`start.sh` starts a local `rmw_zenohd` for the lifetime of the boot.
Scene, Mapping, and Nav2 are explicitly selected for their Jetson-native paths.

## Prepare

Install the Robonix `dev` toolchain from its source clone, then install the
ROS dependencies once:

```bash
cd ~/wheatfox/robonix
git switch dev
git pull --ff-only origin dev
make install

sudo apt install ros-humble-rmw-zenoh-cpp \
  ros-humble-rtabmap-ros ros-humble-navigation2 ros-humble-nav2-bringup
```

Create a private environment file; never commit credentials:

```bash
cp .env.example .env
$EDITOR .env
```

`start.sh` loads this ignored file automatically and exports it to every
Robonix child process. Keep VLM and Tencent SecretId/SecretKey here; keep
non-secret backend, AppID, engine, voice, and region settings in
`robonix_manifest.yaml`.

## Build and boot

```bash
bash build.sh
bash start.sh
```

The wrappers set `ROBONIX_DEPLOY_DIR`, source ROS Humble, select the native
Jetson build, and keep the Zenoh router lifecycle tied to `rbnx boot`.

Operator pages:

- Scene: `http://<robot-host>:50107/`
- Mapping: `http://<robot-host>:8091/`
- Atlas for Robonix Client: `<robot-host>:50051`
- Liaison for Robonix Client: `<robot-host>:50081`

## RViz

The deploy keeps the complete v0.1 RViz configuration and an updated mapping
variant. The updated file preserves the original map, costmap, scan, path,
goal, TF, particle-cloud, and footprint displays, and adds the Soma-backed
RobotModel plus the live MID-360 `/scanner/cloud` display.

```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
rviz2 -d rviz/ranger_mapping.rviz
```

The unchanged historical configuration is `rviz/ranger_v0.1.rviz`.

## Safety and bring-up order

Keep the chassis powered off while validating the passive stack. The chassis,
Nav2, and Explore entries remain commented in `robonix_manifest.yaml`; LiDAR,
IMU, camera, Robot Description, Scene, and Mapping can be inspected without exposing
motion capabilities.

After the chassis is powered on:

1. Verify `can_ranger` is UP and odometry is publishing.
2. Send zero Twist and confirm the watchdog holds the base stopped.
3. Use a low-speed, short-duration command in a clear area.
4. Verify Mapping pose and Nav2 costmaps before sending a nearby goal.
5. Only then test Explore.

## Robot description

`soma.yaml` and `urdf/ranger_mini.urdf` are served by Soma. The description
contains the body footprint and sensor tree used by Pilot and other consumers.
Mount transforms remain calibration-sensitive; update the URDF after physical
measurement rather than compensating in Scene or Mapping.
