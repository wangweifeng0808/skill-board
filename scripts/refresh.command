#!/usr/bin/env bash
# Double-click to rescan every configured agent and rebuild the dashboard.
cd "$(dirname "$0")/.." || exit 1

echo "Scanning skills…"
python3 scan_skills.py || { echo "Scan failed."; read -r -p "Press enter to close."; exit 1; }

BOARD=$(python3 - <<'PY'
import json, os
cfg = json.load(open("config.json"))
print(os.path.expanduser(cfg.get("outputs", {}).get("board", "dist/board.html")))
PY
)

echo ""
echo "Done. Board: $BOARD"
[ -f "$BOARD" ] && open "$BOARD"
exit 0
