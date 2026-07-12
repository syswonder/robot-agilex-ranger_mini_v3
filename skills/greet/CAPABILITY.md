---
provider: greet
kind: skill
description: Passerby greeting — watch the front camera, detect people (YOLO) and announce a friendly make-way line (VLM) over the speaker.
---

# greet_rbnx — passerby-greeting skill

Watches the robot's front RGB camera and greets people in its path so they can
make way. Two-stage to keep it cheap: a **local YOLO** person detector runs on
every frame (free, on the Jetson GPU); only when it actually sees people does
the skill call a **VLM** (ofox + a cheap Qwen vision model) for one short,
friendly, witty line asking folks to step aside — then speaks it via
`speech/speak`. A cooldown stops it talking over the same crowd.

The robot base is **never driven** — the only outward action is speech.

## MCP tools

- `robonix/skill/greet/greet` — start the greeting watch (returns immediately).
- `robonix/skill/greet/greet/cancel` — stop it (camera stays subscribed).

## Upstream contracts consumed

- `robonix/primitive/camera/rgb` (ros2 topic) — the front RGB image.
- `robonix/service/speech/speak` (mcp) — announce the line aloud.

## Config (via Driver CMD_INIT)

| key | meaning | default |
|-----|---------|---------|
| `vlm.upstream` / `vlm.api_key` / `vlm.model` | OpenAI-compatible vision endpoint (ofox + a cheap Qwen vision model) | — / — / `qwen-vl-plus` |
| `yolo_conf` | YOLO person confidence threshold | 0.4 |
| `yolo_weights` | path to the YOLO weight file (the robot has no internet) | `weights/yolov8n.pt` |
| `period_s` | seconds between detection cycles | 1.5 |
| `cooldown_s` | min seconds between spoken greetings | 15.0 |
| `speak_target` | speaker provider id (empty = first available) | "" |
