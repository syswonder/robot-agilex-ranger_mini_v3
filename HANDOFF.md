# Ranger Mini bring-up — handoff

你的任务是把 robonix v0.1.2 在 Jetson Orin + Ranger Mini 上**起来**：`rbnx build` 拉所有包、`rbnx boot` 跑起来，看 scene、底盘驱动、导航这些能不能正常 active。语音 / liaison voice / soma（URDF）这一轮**不测**，已经从 manifest 里关掉了。

## 目录在哪

Jetson 上 ssh 进去后：

```bash
ssh syswonder@<jetson-ip>     # 你已经知道地址
```

robonix 主仓在 `/home/syswonder/wheatfox/robonix`（包含 `rbnx` 工具链 + Python pylib + 系统组件）。

部署仓库（这个 repo）放到 `~/robonix-v0.1-deploy/`：

```bash
cd ~
git clone https://github.com/syswonder/robot-agilex-ranger_mini_v3 robonix-v0.1-deploy
cd robonix-v0.1-deploy
```

## 一、build

```bash
rbnx build
```

`rbnx build` 会：
1. clone manifest 里每个 `url:` 对应的包到 `rbnx-boot/cache/<name>/`（mid360_lidar / mid360_imu / realsense_camera / ranger_chassis / mapping / nav2 / explore）
2. 给每个包跑它的 `scripts/build.sh`（colcon / pip / docker，看包）
3. 给每个包做 codegen 生成 atlas + contracts 的 Python stubs

build 跑完每个 cap 应当显示 `✓`。任何包失败先看 `rbnx-boot/logs/<pkg>-build.log`。

## 二、改包

要改任何 url-fetched 的包（比如调 livox 参数 / 改 rtabmap 配置），**直接进 `rbnx-boot/cache/<pkg>/` 改文件**——那是个完整 git clone，可以正常 `git diff` / `git commit` / 自己 push。**不要重新 clone 工作树**——一次 `rbnx build` 后再改不会被覆盖。

如果改完发现要重 build 那个包：进 `rbnx-boot/cache/<pkg>/`，跑 `bash scripts/build.sh`。

## 三、boot

需要 VLM 凭据（pilot 走 LLM 决策必需），用 inline-prepend：

```bash
VLM_API_KEY=sk-... \
VLM_BASE_URL=https://api.ofox.ai/v1 \
VLM_MODEL=gpt-5.4-mini \
rbnx boot
```

（具体凭据问 wheatfox。）

启动顺序：先 system caps（atlas / executor / pilot / liaison / nexus / memory / scene），然后 primitives（lidar / imu / camera / chassis），再 services（mapping / nav2），最后 skill（explore——boot 后停在 `INACTIVE` 等 LLM 调用是正常的，lazy-activate）。

正常完成时输出底部应该是：
```
✓ N component(s) up; logs under .../rbnx-boot/logs
```

## 四、验证

### 4.1 atlas 状态

```bash
rbnx caps -v
```

期待看到所有非 skill 的 cap 都是 `[ACTIVE]`，explore skill 是 `[INACTIVE]`（这是正常的 lazy-activate）。如果某个卡在 `[INACTIVE]` 或 `[ERROR]`，看它的 log。

### 4.2 contracts

```bash
rbnx contracts
```

应能看到 `robonix/primitive/{lidar,imu,camera,chassis}/*` + `robonix/service/{map,navigation}/*` + 各 system 服务的 contract。

### 4.3 scene WebUI

scene 起来会监听一个 HTTP 端口（看 `rbnx-boot/logs/scene.log` 里 `MCP HTTP serving on 0.0.0.0:XXXXX` 这一行；其它 web 端口同理）。浏览器打开看 2D / 3D / 摄像头视图能不能加载、对象能不能识别、底盘 pose 能不能更新。

### 4.4 chat（可选）

```bash
rbnx chat
```

走 liaison → pilot 链路，能不能问"导航到 X"之类的让 explore 被 LLM 路由 → activate → 跑起来。

### 4.5 单 cap 调试（独立测试）

某个包卡住时，跳过 manifest 单独起：

```bash
rbnx start -p rbnx-boot/cache/mid360_lidar -c local_test_config.yaml
```

`-c` 是单包用的配置 yaml，跟 manifest 里 `config:` 段同结构。

## 五、关闭

```
Ctrl-C   # rbnx boot 进程；它会反向 teardown
```

如果遗留进程没清干净（`pgrep -f robonix-` 还有命中）：

```bash
pkill -f robonix-
```

## 六、当前已知关掉的功能

| 功能 | 状态 | 备注 |
|---|---|---|
| soma（URDF / robot_state_publisher）| ☐ | v0.2 roadmap，未实现；用 static_transform_publisher 顶（见 README） |
| 语音 / speech 服务 | ☐ | 麦克风未接，audio primitives 也没列在 manifest |
| liaison voice loop | ☐ | 同上；但 liaison 自身**开**了，因为 `rbnx chat` 要走它 |
| fastlio2 SLAM | 已知 drift | 由 wheatfox 单独测试，**不走 rbnx boot**；当前 mapping 用 rtabmap 算法 |

## 七、卡住找谁

- build 报错 / API 不对 / state machine 逻辑：wheatfox
- 底盘 / lidar / IMU 硬件 / CAN：（你们组对应的硬件同学）
- VLM 凭据 / pilot 路由：wheatfox

build + boot 跑通后给一份 `rbnx caps -v` 的输出截图就是 bring-up 报告。
