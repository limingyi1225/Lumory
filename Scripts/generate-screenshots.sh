#!/usr/bin/env bash
# Lumory App Store screenshot generator.
#
# 跑流程:
#   1. boot iPhone 17 Pro Max simulator (6.9" — App Store 必需的最大尺寸)
#   2. override 状态栏到 9:41 / 满电 / 满信号 (避免出现"测试中"红条 / 真实电量百分比)
#   3. 跑 ChronoteUITests/ScreenshotTests
#   4. 从 .xcresult 把 PNG 提取到 Screenshots/zh-Hans/
#   5. 清除状态栏 override
#
# 用法:
#   ./Scripts/generate-screenshots.sh
#
# 依赖:
#   - Xcode 16+
#   - 可选:`xcparse` (`brew install chargepoint/xcparse/xcparse`) —— 没装时会用 xcresulttool fallback

set -euo pipefail

# ─── 配置 ────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 默认 iPhone 17 Pro Max → 1320×2868(iPhone 6.9"槽,最大尺寸)。
# 想出 iPad 截图就传 device class:
#   ./Scripts/generate-screenshots.sh ipad      → iPad Pro 13" M4 → 2064×2752
#   ./Scripts/generate-screenshots.sh iphone    → iPhone 17 Pro Max(同默认)
# 也可以走 env 自定义任意机型:
#   LUMORY_SIM="iPhone 13 Pro Max - Lumory" ./Scripts/...
#
# App Store Connect 接受的尺寸:
#   iPhone 6.9":1320×2868      iPhone 6.7":1284×2778 / 1290×2796
#   iPhone 6.5":1242×2688      iPhone 6.3":1260×2736
#   iPad Pro 13":2064×2752     iPad Pro 12.9":2048×2732
DEVICE_CLASS="${1:-iphone}"
case "$DEVICE_CLASS" in
    ipad)
        DEFAULT_SIM="iPad Pro 13 - Lumory"
        OUT_SUBDIR="zh-Hans-iPad"
        RESULT_NAME="screenshots-ipad.xcresult"
        ;;
    iphone|*)
        DEFAULT_SIM="iPhone 17 Pro Max"
        OUT_SUBDIR="zh-Hans"
        RESULT_NAME="screenshots.xcresult"
        ;;
esac
SIM_NAME="${LUMORY_SIM:-$DEFAULT_SIM}"
SCHEME="Lumory"
RESULT_BUNDLE="$PROJECT_ROOT/build/$RESULT_NAME"
OUT_DIR="$PROJECT_ROOT/Screenshots/$OUT_SUBDIR"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"

# ─── 颜色 ────────────────────────────────────────────────────────────
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m"

log()  { echo -e "${GREEN}==> $*${NC}"; }
warn() { echo -e "${YELLOW}!! $*${NC}"; }
err()  { echo -e "${RED}xx $*${NC}" >&2; }

# ─── 1. 准备目录 ─────────────────────────────────────────────────────
log "清理之前的产物"
rm -rf "$RESULT_BUNDLE"
# **必须清空 OUT_DIR 里的旧 PNG**:如果上一次跑 6 张、这次只跑成功 4 张,
# 不清会留 2 张旧截图,最终 count + App Store 上传集合混进老照片。
# 只删 .png,保留目录本身和可能存在的非截图文件(比如 .DS_Store)。
if [ -d "$OUT_DIR" ]; then
    find "$OUT_DIR" -maxdepth 1 -type f -name "*.png" -delete
fi
mkdir -p "$OUT_DIR"
mkdir -p "$(dirname "$RESULT_BUNDLE")"

# ─── 2. 选/启 模拟器 ────────────────────────────────────────────────
log "查找模拟器: $SIM_NAME"
SIM_UDID="$(xcrun simctl list devices available -j \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '$SIM_NAME'
for runtime, devices in data['devices'].items():
    for d in devices:
        if d['name'] == target and d.get('isAvailable', False):
            print(d['udid'])
            sys.exit(0)
")"

if [ -z "$SIM_UDID" ]; then
    err "找不到名为 '$SIM_NAME' 的可用模拟器"
    err "可用列表:"
    xcrun simctl list devices available | grep -E "iPhone (16|17) Pro Max" >&2 || true
    exit 1
fi
log "使用模拟器 UDID: $SIM_UDID"

# Boot if needed (booted 时 boot 会返一个无害的 'already booted' 错误)
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true

# 等模拟器完全启动
log "等模拟器就位 (最长 60s)"
xcrun simctl bootstatus "$SIM_UDID" -b

# ─── 3. 状态栏 override ──────────────────────────────────────────────
log "覆盖状态栏 (9:41 / 满电 / 满信号 / WiFi 满格)"
xcrun simctl status_bar "$SIM_UDID" override \
    --time "9:41" \
    --dataNetwork "wifi" \
    --wifiMode "active" \
    --wifiBars 3 \
    --cellularMode "active" \
    --cellularBars 4 \
    --batteryState "charged" \
    --batteryLevel 100 || warn "status_bar override 部分失败 (老版本 simctl 可能不支持某些字段)"

# ─── 4. 跑测试 ───────────────────────────────────────────────────────
# 关掉并发 + clone 模拟器:默认 xcodebuild test 会 clone 我们指定的 sim,clone 不会继承
# 我们刚 override 的 status bar(9:41 / 满电),所以截出来角上一坨真实数字。强制走原始 sim。
log "运行 ScreenshotTests (xcodebuild test)"
set +e
# **注意:不要用 `xcodebuild ... | grep ... || true`**——`|| true` 会覆盖 PIPESTATUS,
# TEST_RC 永远是 0,测试真正失败时下面的 warn 分支永远不触发,整个脚本装作成功继续跑。
# 已经 `set +e`,pipeline 非零不会让脚本退出;grep 的 exit code 不用我们关心,PIPESTATUS[0]
# 就是 xcodebuild 的真实状态。
xcodebuild test \
    -project "$PROJECT_ROOT/Lumory.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:ChronoteUITests/ScreenshotTests \
    -resultBundlePath "$RESULT_BUNDLE" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    -disable-concurrent-destination-testing \
    -quiet \
    2>&1 | grep -E "Test Suite|Test Case|error:|FAILED|PASSED|crashed"
TEST_RC=${PIPESTATUS[0]}
set -e

if [ "$TEST_RC" -ne 0 ]; then
    warn "xcodebuild test 返回非零 ($TEST_RC) —— 部分截图可能仍然成功了,继续提取"
fi

# ─── 5. 提取截图 ─────────────────────────────────────────────────────
log "从 .xcresult 提取 PNG → $OUT_DIR"

# Xcode 16+ 自带 `xcresulttool export attachments`,不需要 xcparse 也能干净拿到所有截图。
# 输出文件名是 attachment UUID(GUID.png),配合 manifest.json 把它们 rename 成
# `01-Home.png` / `02-Insights.png` 这样的人类可读名。
EXPORT_TMP="$(mktemp -d)"
xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$EXPORT_TMP" >/dev/null

# manifest.json 结构(简化):
#   [
#     { "testIdentifier": "ScreenshotTests/test_01_Home()",
#       "attachments": [ { "exportedFileName": "UUID.png", "suggestedHumanReadableName": "01-Home_0_xxx.png" }, ... ]
#     },
#     ...
#   ]
# 我们想要 OUT_DIR/01-Home.png(去掉 _0_GUID 后缀,保留排序前缀)。
python3 - "$EXPORT_TMP" "$OUT_DIR" <<'PYEOF'
import json
import re
import shutil
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)

manifest_path = src / "manifest.json"
if not manifest_path.exists():
    print(f"!! manifest.json 不存在,直接拷贝所有 PNG")
    for png in src.glob("*.png"):
        shutil.copy(png, dst / png.name)
    sys.exit(0)

manifest = json.loads(manifest_path.read_text())
count = 0
for test in manifest:
    for att in test.get("attachments", []):
        exported = att.get("exportedFileName")
        suggested = att.get("suggestedHumanReadableName") or exported
        if not exported:
            continue
        src_file = src / exported
        if not src_file.exists():
            continue
        # suggested 里通常是 "01-Home_0_GUID.png" —— 把 _0_GUID 部分去掉
        clean = re.sub(r"_\d+_[A-F0-9-]+(?=\.png$)", "", suggested)
        out_file = dst / clean
        shutil.copy(src_file, out_file)
        print(f"  → {out_file.name}")
        count += 1
print(f"Extracted {count} screenshots")
PYEOF

rm -rf "$EXPORT_TMP"

# ─── 6. 清除状态栏 override ──────────────────────────────────────────
log "清除状态栏 override"
xcrun simctl status_bar "$SIM_UDID" clear || true

# ─── 7. 总结 ─────────────────────────────────────────────────────────
COUNT="$(find "$OUT_DIR" -name "*.png" -type f | wc -l | tr -d ' ')"
echo
log "完成。生成 $COUNT 张 PNG → $OUT_DIR"
echo
echo "下一步:"
echo "  1. 检查截图: open '$OUT_DIR'"
echo "  2. 在 App Store Connect 上传 (iPhone 6.9\" 槽位):"
echo "     https://appstoreconnect.apple.com"
echo "  3. 6.9\" 截图会被 Apple 自动缩放到其他尺寸,无需另传"
