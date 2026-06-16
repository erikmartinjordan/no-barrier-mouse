#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 erik@iMac-de-Erik.local [cycles] [run-dir]" >&2
  exit 1
fi

HOST="$1"
CYCLES="${2:-50}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${3:-/tmp/no-barrier-e2e-real-$(date +%Y%m%d-%H%M%S)}"

LOCAL_APP="$ROOT_DIR/.build/release/native/NoBarrierMouse.app"
REMOTE_APP_SOURCE="$ROOT_DIR/.build/release/intel/NoBarrierMouse.app"
LOCAL_INSTALL="$HOME/Applications/NoBarrierMouse-E2E.app"
REMOTE_INSTALL="\$HOME/Applications/NoBarrierMouse-E2E.app"

PAYLOAD_FILE="$RUN_DIR/payload.txt"
REMOTE_PAYLOAD="/tmp/no-barrier-mouse-e2e-payload.txt"
LOCAL_LOG_DIR="$RUN_DIR/local-receiver-logs"
REMOTE_RUN_DIR="/tmp/$(basename "$RUN_DIR")-controller"
REMOTE_LOG_DIR="$REMOTE_RUN_DIR/logs"
REMOTE_FRAME_DIR="$REMOTE_RUN_DIR/imac"

LOCAL_FRAME_DIR="$RUN_DIR/macbook"
IMAC_FRAME_DIR="$RUN_DIR/imac"
COMBINED_FRAME_DIR="$RUN_DIR/combined"
VIDEO_PATH="$RUN_DIR/no-barrier-mouse-e2e-side-by-side.mp4"
CONTACT_PATH="$RUN_DIR/contact.jpg"
SUMMARY_PATH="$RUN_DIR/summary.json"

FRAMES="${E2E_CAPTURE_FRAMES:-680}"
INTERVAL="${E2E_CAPTURE_INTERVAL:-0.16}"
FPS="${E2E_VIDEO_FPS:-12}"
KEEPALIVE_SECONDS="${E2E_KEEPALIVE_SECONDS:-240}"

mkdir -p "$RUN_DIR" "$LOCAL_LOG_DIR" "$LOCAL_FRAME_DIR" "$IMAC_FRAME_DIR" "$COMBINED_FRAME_DIR" "$HOME/Applications"
printf "NoBarrierMouse unattended E2E payload.\nThis text must survive Cmd-V and Cmd-C across both Macs.\n" > "$PAYLOAD_FILE"

if [[ ! -d "$LOCAL_APP" ]]; then
  echo "Native app bundle not found: $LOCAL_APP" >&2
  exit 1
fi

if [[ ! -d "$REMOTE_APP_SOURCE" ]]; then
  echo "Intel app bundle not found: $REMOTE_APP_SOURCE" >&2
  exit 1
fi

echo "Stopping old NoBarrierMouse processes..."
/usr/bin/pkill -x NoBarrierMouse >/dev/null 2>&1 || true
ssh "$HOST" "/usr/bin/pkill -x NoBarrierMouse >/dev/null 2>&1 || true; mkdir -p \"\$HOME/Applications\" \"$REMOTE_LOG_DIR\" \"$REMOTE_FRAME_DIR\""

echo "Installing local receiver bundle..."
rsync -a --delete "$LOCAL_APP/" "$LOCAL_INSTALL/"

echo "Installing iMac controller bundle..."
rsync -a --delete "$REMOTE_APP_SOURCE/" "$HOST:$REMOTE_INSTALL/"
scp "$PAYLOAD_FILE" "$HOST:$REMOTE_PAYLOAD" >/dev/null

capture_local() {
  local i n
  i=0
  while [[ "$i" -lt "$FRAMES" ]]; do
    n="$(printf "%04d" "$i")"
    /usr/sbin/screencapture -C -x "$LOCAL_FRAME_DIR/macbook-$n.png" >/dev/null 2>&1 || true
    i=$((i + 1))
    sleep "$INTERVAL"
  done
}

echo "Starting real screen capture on both Macs..."
/usr/bin/caffeinate -dimsu -t "$KEEPALIVE_SECONDS" >/dev/null 2>&1 &
LOCAL_CAFFEINATE_PID=$!
ssh "$HOST" "/usr/bin/caffeinate -dimsu -t \"$KEEPALIVE_SECONDS\" >/dev/null 2>&1 &"
sleep 1

capture_local &
LOCAL_CAPTURE_PID=$!

ssh "$HOST" "REMOTE_FRAME_DIR='$REMOTE_FRAME_DIR' FRAMES='$FRAMES' INTERVAL='$INTERVAL' /bin/bash -s" <<'REMOTE_CAPTURE' &
set -euo pipefail
i=0
mkdir -p "$REMOTE_FRAME_DIR"
while [[ "$i" -lt "$FRAMES" ]]; do
  n="$(printf "%04d" "$i")"
  /usr/sbin/screencapture -C -x "$REMOTE_FRAME_DIR/imac-$n.png" >/dev/null 2>&1 || true
  i=$((i + 1))
  sleep "$INTERVAL"
done
REMOTE_CAPTURE
REMOTE_CAPTURE_PID=$!

echo "Launching MacBook receiver..."
/usr/bin/open -n "$LOCAL_INSTALL" --args \
  --role receiver \
  --test-mode \
  --test-payload-file "$PAYLOAD_FILE" \
  --test-log-dir "$LOCAL_LOG_DIR"

sleep 3

echo "Launching iMac controller for $CYCLES cycles..."
ssh "$HOST" "/usr/bin/open -n \"$REMOTE_INSTALL\" --args --role controller --test-mode --test-cycles \"$CYCLES\" --test-payload-file \"$REMOTE_PAYLOAD\" --test-log-dir \"$REMOTE_LOG_DIR\""

wait "$LOCAL_CAPTURE_PID" || true
wait "$REMOTE_CAPTURE_PID" || true

echo "Collecting logs and iMac frames..."
rsync -a "$HOST:$REMOTE_FRAME_DIR/" "$IMAC_FRAME_DIR/"
scp "$HOST:$REMOTE_LOG_DIR/latest-diagnostics.json" "$RUN_DIR/controller-latest.json" >/dev/null 2>&1 || true
scp "$HOST:$REMOTE_LOG_DIR/events.jsonl" "$RUN_DIR/controller-events.jsonl" >/dev/null 2>&1 || true
cp "$LOCAL_LOG_DIR/latest-diagnostics.json" "$RUN_DIR/receiver-latest.json" 2>/dev/null || true
cp "$LOCAL_LOG_DIR/events.jsonl" "$RUN_DIR/receiver-events.jsonl" 2>/dev/null || true

echo "Stopping test apps..."
/usr/bin/pkill -x NoBarrierMouse >/dev/null 2>&1 || true
/bin/kill "$LOCAL_CAFFEINATE_PID" >/dev/null 2>&1 || true
ssh "$HOST" "/usr/bin/pkill -x NoBarrierMouse >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

echo "Rendering side-by-side video..."
python3 - "$RUN_DIR" "$IMAC_FRAME_DIR" "$LOCAL_FRAME_DIR" "$COMBINED_FRAME_DIR" "$VIDEO_PATH" "$CONTACT_PATH" "$SUMMARY_PATH" "$CYCLES" "$FPS" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

run_dir = Path(sys.argv[1])
imac_dir = Path(sys.argv[2])
macbook_dir = Path(sys.argv[3])
combined_dir = Path(sys.argv[4])
video_path = Path(sys.argv[5])
contact_path = Path(sys.argv[6])
summary_path = Path(sys.argv[7])
cycles = int(sys.argv[8])
fps = int(sys.argv[9])

imac_frames = sorted(imac_dir.glob("imac-*.png"))
macbook_frames = sorted(macbook_dir.glob("macbook-*.png"))
frame_count = min(len(imac_frames), len(macbook_frames))
if frame_count < 5:
    raise SystemExit(f"Not enough captured frames: iMac={len(imac_frames)} MacBook={len(macbook_frames)}")

target_h = 720
gap = 10
label_h = 34
font = ImageFont.load_default()

def fit(img):
    w, h = img.size
    target_w = round(w * target_h / h)
    return img.resize((target_w, target_h), Image.Resampling.LANCZOS)

for idx, (imac_path, macbook_path) in enumerate(zip(imac_frames[:frame_count], macbook_frames[:frame_count])):
    imac = fit(Image.open(imac_path).convert("RGB"))
    macbook = fit(Image.open(macbook_path).convert("RGB"))
    frame = Image.new("RGB", (imac.width + gap + macbook.width, target_h + label_h), (28, 28, 30))
    draw = ImageDraw.Draw(frame)
    frame.paste(imac, (0, label_h))
    frame.paste(macbook, (imac.width + gap, label_h))
    draw.text((12, 10), "iMac controller", fill=(235, 235, 238), font=font)
    draw.text((imac.width + gap + 12, 10), "MacBook receiver", fill=(235, 235, 238), font=font)
    frame.save(combined_dir / f"frame-{idx:04d}.jpg", quality=88)

subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-framerate", str(fps),
    "-i", str(combined_dir / "frame-%04d.jpg"),
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
    str(video_path),
], check=True)

cols, rows = 8, 6
thumbs = []
for i in range(cols * rows):
    source_index = round(i * (frame_count - 1) / max(1, cols * rows - 1))
    thumbs.append(Image.open(combined_dir / f"frame-{source_index:04d}.jpg").resize((360, 108), Image.Resampling.LANCZOS))
sheet = Image.new("RGB", (cols * 360, rows * 108), (20, 20, 22))
for i, thumb in enumerate(thumbs):
    sheet.paste(thumb, ((i % cols) * 360, (i // cols) * 108))
sheet.save(contact_path, quality=88)

def load_latest(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}

def load_json_stream(path):
    if not path.exists():
        return []
    text = path.read_text()
    decoder = json.JSONDecoder()
    idx = 0
    out = []
    while idx < len(text):
        while idx < len(text) and text[idx].isspace():
            idx += 1
        if idx >= len(text):
            break
        try:
            obj, end = decoder.raw_decode(text, idx)
        except json.JSONDecodeError:
            break
        out.append(obj)
        idx = end
    return out

controller = load_latest(run_dir / "controller-latest.json")
receiver = load_latest(run_dir / "receiver-latest.json")
controller_events = load_json_stream(run_dir / "controller-events.jsonl")
receiver_events = load_json_stream(run_dir / "receiver-events.jsonl")

trap_events = [e for e in controller_events if "trap" in str(e.get("reason", ""))]
recovery_events = [e for e in controller_events if "recovery-before" in str(e.get("reason", ""))]
clipboard_received = [e for e in controller_events if e.get("reason") == "clipboard-result-received"]
bad_clipboard = [e for e in clipboard_received if not (e.get("pasteSucceeded") and e.get("copySucceeded"))]
receiver_results = [e for e in receiver_events if e.get("reason") == "clipboard-result-sent"]
bad_receiver_results = [e for e in receiver_results if not (e.get("pasteSucceeded") and e.get("copySucceeded"))]

summary = {
    "runDir": str(run_dir),
    "video": str(video_path),
    "contactSheet": str(contact_path),
    "capturedFrames": frame_count,
    "controllerCompleted": bool(controller.get("testCompleted")),
    "controllerCycle": controller.get("testCycle"),
    "controllerCycles": controller.get("testCycles"),
    "controllerRecoveries": controller.get("testRecoveries"),
    "controllerClipboardResults": controller.get("clipboardResults"),
    "controllerClipboardFailures": controller.get("clipboardFailures"),
    "controllerTrapEvents": len(trap_events),
    "controllerRecoveryEvents": len(recovery_events),
    "receiverClipboardResults": len(receiver_results),
    "badClipboardEvents": len(bad_clipboard) + len(bad_receiver_results),
    "controllerAccessibilityProblem": controller.get("accessibilityProblem"),
    "controllerInputMonitoringProblem": controller.get("inputMonitoringProblem"),
    "receiverAccessibilityProblem": receiver.get("accessibilityProblem"),
    "receiverInputMonitoringProblem": receiver.get("inputMonitoringProblem"),
}
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True))
print(json.dumps(summary, indent=2, sort_keys=True))

failed = []
if summary["controllerCompleted"] is not True:
    failed.append("controller did not complete")
if summary["controllerCycle"] != cycles or summary["controllerCycles"] != cycles:
    failed.append("controller cycle count mismatch")
if summary["controllerRecoveries"] not in (0, None):
    failed.append("controller recovered during test")
if summary["controllerTrapEvents"] != 0 or summary["controllerRecoveryEvents"] != 0:
    failed.append("trap/recovery events were logged")
if summary["controllerClipboardResults"] != cycles or summary["controllerClipboardFailures"] != 0:
    failed.append("controller clipboard validation failed")
if summary["receiverClipboardResults"] != cycles or summary["badClipboardEvents"] != 0:
    failed.append("receiver clipboard validation failed")
if summary["controllerAccessibilityProblem"] or summary["controllerInputMonitoringProblem"]:
    failed.append("controller permissions problem")
if summary["receiverAccessibilityProblem"] or summary["receiverInputMonitoringProblem"]:
    failed.append("receiver permissions problem")
if failed:
    raise SystemExit("; ".join(failed))
PY

echo "E2E video: $VIDEO_PATH"
echo "Contact sheet: $CONTACT_PATH"
echo "Summary: $SUMMARY_PATH"
