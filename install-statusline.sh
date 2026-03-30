#!/bin/bash

# Claude Code Statusline Installer
# Installs custom statusline configuration at the global level (~/.claude)
# Includes session cost tracking and exit watchdog

set -e

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATUSLINE_SCRIPT="$CLAUDE_DIR/statusline.sh"
COST_LOGGER="$HOOKS_DIR/log_session_cost.py"

echo "Installing Claude Code custom statusline..."

# Create directories
mkdir -p "$CLAUDE_DIR"
mkdir -p "$HOOKS_DIR"

# Create the session cost logger script
cat > "$COST_LOGGER" << 'COST_EOF'
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["gspread"]
# ///
"""Claude Code Hook - Log session cost to CSV and Google Sheets.

Always upserts by session_id so both live statusline ticks and the
Stop hook write to the same row without creating duplicates.

Reads cost data directly from stdin (per-session JSON) to avoid
cross-session contamination via the shared statusline-debug.json file.
Writes to ~/.claude/session-costs.csv and syncs to Google Sheets.

Uses PID-based reaping: each session stores the Claude Code process PID.
On every --live tick, stale "alive" sessions whose PIDs are dead get
marked as "concluded".

Google Sheets sync is throttled to once per 60 seconds for live ticks
to stay within API rate limits. Conclude events always sync immediately.

Environment variables:
  CLAUDE_COST_SHEET_ID  - Google Sheet ID (required for Sheets sync)
  CLAUDE_COST_SA_KEY    - Path to service account JSON key (required for Sheets sync)
"""

import csv
import fcntl
import json
import os
import sys
import socket
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

LOCAL_TZ = timezone(timedelta(hours=8))
COST_LOG = Path.home() / ".claude" / "session-costs.csv"
LOCK_PATH = COST_LOG.with_suffix(".lock")
SHEETS_LOCK_PATH = Path.home() / ".claude" / ".sheets-sync.lock"
THROTTLE_FILE = Path.home() / ".claude" / ".sheets-sync-ts"
SHEETS_THROTTLE_SECS = 60

SHEET_ID = os.environ.get("CLAUDE_COST_SHEET_ID", "")
SA_KEY_PATH = os.environ.get("CLAUDE_COST_SA_KEY", "")

HEADERS = [
    "timestamp",
    "session_id",
    "project",
    "model",
    "total_cost_usd",
    "total_input_tokens",
    "total_output_tokens",
    "context_used_pct",
    "hostname",
    "status",
    "pid",
]


class CsvLock:
    """Exclusive file lock so concurrent read-modify-writes don't race."""

    def __enter__(self):
        self._f = open(LOCK_PATH, "w")
        fcntl.flock(self._f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *args):
        fcntl.flock(self._f, fcntl.LOCK_UN)
        self._f.close()


class SheetsLock:
    """Exclusive lock for Google Sheets sync to prevent concurrent appends.

    Without this, two concurrent processes can both ws.find() → None and
    both ws.append_row(), creating duplicate rows.
    """

    def __enter__(self):
        self._f = open(SHEETS_LOCK_PATH, "w")
        fcntl.flock(self._f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *args):
        fcntl.flock(self._f, fcntl.LOCK_UN)
        self._f.close()


def is_pid_alive(pid: int) -> bool:
    """Check if a process with the given PID is still running."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def build_row(input_data: dict, live_mode: bool, pid: str = "") -> dict:
    """Build a CSV row dict directly from stdin JSON (per-session, no shared file)."""
    session_id = input_data.get("session_id", "unknown")
    cwd = input_data.get("cwd", "")
    project = Path(cwd).name if cwd else "unknown"
    hostname = socket.gethostname()
    timestamp = datetime.now(LOCAL_TZ).strftime("%Y-%m-%d %H:%M:%S")

    cost = input_data.get("cost", {})
    ctx = input_data.get("context_window", {})

    return {
        "timestamp": timestamp,
        "session_id": session_id,
        "project": project,
        "model": input_data.get("model", {}).get("display_name", ""),
        "total_cost_usd": cost.get("total_cost_usd", 0),
        "total_input_tokens": ctx.get("total_input_tokens", 0),
        "total_output_tokens": ctx.get("total_output_tokens", 0),
        "context_used_pct": round(ctx.get("used_percentage") or 0, 1),
        "hostname": hostname,
        "status": "alive" if live_mode else "concluded",
        "pid": pid,
    }


def upsert_row(row: dict, reap_stale: bool = False) -> tuple[list[str], list[str]]:
    """Update existing row for session_id in-place, or append if not found.

    When reap_stale is True (live mode), check all other "alive" sessions:
    - Same PID, different session_id (/clear): **replace** the old row with the
      new session data so only one row exists per Claude process.  The cost
      counter is cumulative per-process, so keeping both rows double-counts.
    - Dead PID or missing PID: mark as "concluded" (reaped).

    Returns (reaped_session_ids, replaced_old_session_ids).
    Reaped sessions need their own Sheets sync (concluded).
    Replaced sessions need the current row synced to Sheets using the old
    session_id as a fallback lookup key.
    """
    with CsvLock():
        session_id = row["session_id"]
        current_pid = row.get("pid", "").strip()
        rows: list[dict] = []
        reaped: list[str] = []
        replaced: list[str] = []  # old session_ids replaced by current session
        found = False

        if COST_LOG.exists():
            with open(COST_LOG, "r", newline="") as f:
                reader = csv.DictReader(f)
                for existing in reader:
                    if existing["session_id"] == session_id:
                        # Overwrite protection: don't let a late "alive" tick
                        # overwrite a row already marked "concluded"
                        if (existing.get("status") == "concluded"
                                and row.get("status") == "alive"
                                and current_pid
                                and existing.get("pid", "").strip() == current_pid):
                            row = dict(row)
                            row["status"] = "concluded"
                        rows.append(row)
                        found = True
                    else:
                        if reap_stale and existing.get("status") == "alive":
                            pid_str = existing.get("pid", "").strip()
                            # Same PID, different session_id → /clear or resume
                            # Replace the old row with new session data instead
                            # of keeping both (cost is cumulative per-process).
                            if current_pid and pid_str == current_pid:
                                replaced.append(existing["session_id"])
                                if not found:
                                    # Put the new row in the old row's position
                                    rows.append(row)
                                    found = True
                                # else: already inserted new row, just drop old
                                continue
                            elif pid_str and pid_str.isdigit():
                                if not is_pid_alive(int(pid_str)):
                                    existing["status"] = "concluded"
                                    reaped.append(existing["session_id"])
                            else:
                                # No PID recorded — legacy row, mark concluded
                                existing["status"] = "concluded"
                                reaped.append(existing["session_id"])
                        # Ensure status field exists for old rows
                        existing.setdefault("status", "")
                        existing.setdefault("pid", "")
                        rows.append(existing)

        if not found:
            rows.append(row)

        with open(COST_LOG, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=HEADERS)
            writer.writeheader()
            writer.writerows(rows)

    return reaped, replaced


def conclude_session(session_id: str, expected_pid: str = "") -> None:
    """Mark a specific session as concluded (called by the exit watchdog).

    If expected_pid is provided, only conclude when the stored PID matches.
    This prevents a slow old watchdog from overwriting "alive" after a
    session has been resumed with a new PID.
    """
    if not COST_LOG.exists():
        return

    with CsvLock():
        rows: list[dict] = []
        with open(COST_LOG, "r", newline="") as f:
            reader = csv.DictReader(f)
            for existing in reader:
                if existing["session_id"] == session_id:
                    stored_pid = existing.get("pid", "").strip()
                    if not expected_pid or stored_pid == expected_pid or not stored_pid:
                        existing["status"] = "concluded"
                    # else: PID changed (session resumed), skip
                existing.setdefault("status", "")
                existing.setdefault("pid", "")
                rows.append(existing)

        with open(COST_LOG, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=HEADERS)
            writer.writeheader()
            writer.writerows(rows)


def conclude_by_pid(pid: str) -> list[str]:
    """Mark ALL alive sessions with the given PID as concluded.

    Returns the list of session IDs that were concluded.
    This handles the case where /clear creates multiple sessions under
    the same PID — the watchdog can conclude them all at once.
    """
    if not COST_LOG.exists():
        return []

    concluded: list[str] = []
    with CsvLock():
        rows: list[dict] = []
        with open(COST_LOG, "r", newline="") as f:
            reader = csv.DictReader(f)
            for existing in reader:
                if (existing.get("status") == "alive"
                        and existing.get("pid", "").strip() == pid):
                    existing["status"] = "concluded"
                    concluded.append(existing["session_id"])
                existing.setdefault("status", "")
                existing.setdefault("pid", "")
                rows.append(existing)

        with open(COST_LOG, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=HEADERS)
            writer.writeheader()
            writer.writerows(rows)

    return concluded


# --- Google Sheets sync ---

def should_sync_sheets(force: bool = False) -> bool:
    """Check if we should sync to Google Sheets (throttle for live ticks)."""
    if not SHEET_ID or not SA_KEY_PATH:
        return False
    if not Path(SA_KEY_PATH).exists():
        return False
    if force:
        return True
    # Throttle: only sync once per SHEETS_THROTTLE_SECS
    if THROTTLE_FILE.exists():
        age = time.time() - THROTTLE_FILE.stat().st_mtime
        if age < SHEETS_THROTTLE_SECS:
            return False
    return True


def touch_throttle():
    """Update the throttle timestamp."""
    THROTTLE_FILE.touch()


def sync_to_sheets(row: dict, old_session_id: str = "") -> bool:
    """Upsert a row in Google Sheets by session_id.

    Protected by SheetsLock to prevent concurrent find+append races
    where two processes both see no existing row and both append.

    If old_session_id is provided (from a /clear replacement), the old
    Sheets row is found by that ID and updated in-place with the new
    session data, preventing duplicate rows.
    """
    try:
        import gspread

        with SheetsLock():
            gc = gspread.service_account(filename=SA_KEY_PATH)
            sh = gc.open_by_key(SHEET_ID)
            ws = sh.sheet1

            # Ensure headers exist
            try:
                existing_headers = ws.row_values(1)
            except Exception:
                existing_headers = []

            if not existing_headers:
                ws.append_row(HEADERS)
                existing_headers = HEADERS

            # Build the row values in header order
            row_values = [str(row.get(h, "")) for h in HEADERS]

            # Find existing row by session_id (column B = index 2)
            session_id = row["session_id"]
            try:
                cell = ws.find(session_id, in_column=2)
            except gspread.exceptions.CellNotFound:
                cell = None

            # Fallback: find by old session_id (after /clear replaced it)
            if not cell and old_session_id:
                try:
                    cell = ws.find(old_session_id, in_column=2)
                except gspread.exceptions.CellNotFound:
                    cell = None

            if cell:
                # Update existing row
                row_number = cell.row
                ws.update(f"A{row_number}:{chr(64 + len(HEADERS))}{row_number}", [row_values])
            else:
                # Append new row
                ws.append_row(row_values)

            touch_throttle()
        return True
    except Exception as e:
        print(f"Sheets sync failed: {e}", file=sys.stderr)
        return False


def get_row_by_session(session_id: str) -> dict | None:
    """Read the full row for a session_id from the local CSV."""
    if not COST_LOG.exists():
        return None
    with open(COST_LOG, "r", newline="") as f:
        for row in csv.DictReader(f):
            if row["session_id"] == session_id:
                return row
    return None


def main():
    # Handle --conclude-pid mode (called by the exit watchdog)
    # Concludes ALL alive sessions under the given PID and syncs each to Sheets.
    if "--conclude-pid" in sys.argv:
        idx = sys.argv.index("--conclude-pid")
        if idx + 1 < len(sys.argv):
            pid = sys.argv[idx + 1]
            concluded = conclude_by_pid(pid)
            for sid in concluded:
                print(f"Session {sid} marked concluded (PID {pid})", file=sys.stderr)
                if should_sync_sheets(force=True):
                    row = get_row_by_session(sid)
                    if row:
                        sync_to_sheets(row)
                        print(f"Sheets synced final cost for {sid}", file=sys.stderr)
            if not concluded:
                print(f"No alive sessions found for PID {pid}", file=sys.stderr)
        sys.exit(0)

    # Handle --conclude-session mode (legacy, kept for compatibility)
    if "--conclude-session" in sys.argv:
        idx = sys.argv.index("--conclude-session")
        if idx + 1 < len(sys.argv):
            sid = sys.argv[idx + 1]
            # Parse --pid to guard against race with resumed sessions
            wpid = ""
            if "--pid" in sys.argv:
                pidx = sys.argv.index("--pid")
                if pidx + 1 < len(sys.argv):
                    wpid = sys.argv[pidx + 1]
            conclude_session(sid, wpid)
            print(f"Session {sid} marked concluded", file=sys.stderr)
            # Sync full row (including final cost) to Sheets
            if should_sync_sheets(force=True):
                row = get_row_by_session(sid)
                if row:
                    sync_to_sheets(row)
                    print(f"Sheets synced final cost for {sid}", file=sys.stderr)
        sys.exit(0)

    live_mode = "--live" in sys.argv

    # Parse --pid argument (Claude Code process PID from statusline $PPID)
    pid = ""
    if "--pid" in sys.argv:
        idx = sys.argv.index("--pid")
        if idx + 1 < len(sys.argv):
            pid = sys.argv[idx + 1]

    try:
        input_data = json.load(sys.stdin)
    except Exception:
        input_data = {}

    row = build_row(input_data, live_mode, pid)

    # Always upsert to local CSV; in live mode also reap stale sessions.
    reaped, replaced = upsert_row(row, reap_stale=live_mode)

    # Sync reaped sessions to Google Sheets (force=True, they need final sync)
    for reaped_sid in reaped:
        if should_sync_sheets(force=True):
            reaped_row = get_row_by_session(reaped_sid)
            if reaped_row:
                sync_to_sheets(reaped_row)
                print(f"Sheets synced reaped session {reaped_sid}", file=sys.stderr)

    # Sync to Google Sheets (throttled for live, always for stop).
    # Force sync when a /clear replacement happened so the old Sheets row
    # gets updated before the next tick tries to find by the new session_id.
    # Pass the old session_id so sync_to_sheets can find and update the
    # existing Sheets row instead of appending a duplicate.
    force_sync = bool(replaced) or not live_mode
    old_sid = replaced[0] if replaced else ""
    if should_sync_sheets(force=force_sync):
        if sync_to_sheets(row, old_session_id=old_sid):
            print(f"Sheets synced", file=sys.stderr)
            if replaced:
                print(f"Replaced old session(s) {replaced} in Sheets", file=sys.stderr)

    print(f"Session cost logged ({('live' if live_mode else 'final')}): ${row['total_cost_usd']}", file=sys.stderr)
    sys.exit(0)


if __name__ == "__main__":
    main()
COST_EOF

chmod +x "$COST_LOGGER"
echo "Created session cost logger: $COST_LOGGER"

# Create the statusline.sh script
cat > "$STATUSLINE_SCRIPT" << 'STATUSLINE_EOF'
#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Resolve the stable Claude Code process PID by walking up the process tree.
# $PPID is a transient intermediate process that dies quickly, which breaks
# the watchdog and PID-based reaping. We need the actual 'claude' process.
find_claude_pid() {
  local pid=$PPID
  while [ "$pid" -gt 1 ]; do
    # Get the executable base name (works on both macOS and Linux)
    local comm
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null)
    if [ "$comm" = "claude" ]; then
      echo "$pid"
      return
    fi
    # Walk up to the parent process
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
  done
  echo "$PPID"  # fallback
}
CLAUDE_PID=$(find_claude_pid)

# Debug: Write all input and parsed variables to debug file
debug_file="/tmp/statusline-debug.log"
debug_json="$HOME/.claude/statusline-debug.json"
{
  echo "=== Status Line Debug Log ==="
  echo "Timestamp: $(date)"
  echo ""
  echo "=== RAW JSON INPUT ==="
  echo "$input"
  echo ""
} > "$debug_file"

# Write the raw JSON to a separate file for easy inspection
echo "$input" | python3 -m json.tool > "$debug_json" 2>/dev/null || echo "$input" > "$debug_json"

# Parse JSON data using grep and sed (jq-free approach)
model_name=$(echo "$input" | grep -o '"display_name":"[^"]*"' | head -1 | sed 's/"display_name":"//;s/"$//')
current_dir_path=$(echo "$input" | grep -o '"current_dir":"[^"]*"' | sed 's/"current_dir":"//;s/"$//')
project_name=$(basename "$current_dir_path")

# Get context window data
used_pct=$(echo "$input" | grep -o '"used_percentage":[0-9.]*' | head -1 | sed 's/"used_percentage"://')

# Extract the current_usage object and parse its fields
# This approach extracts everything between "current_usage":{...}
current_usage_block=$(echo "$input" | grep -o '"current_usage":{[^}]*}' | head -1)
if [ -n "$current_usage_block" ]; then
  current_input=$(echo "$current_usage_block" | grep -o '"input_tokens":[0-9]*' | sed 's/"input_tokens"://')
  current_output=$(echo "$current_usage_block" | grep -o '"output_tokens":[0-9]*' | sed 's/"output_tokens"://')
  cache_creation=$(echo "$current_usage_block" | grep -o '"cache_creation_input_tokens":[0-9]*' | sed 's/"cache_creation_input_tokens"://')
  cache_read=$(echo "$current_usage_block" | grep -o '"cache_read_input_tokens":[0-9]*' | sed 's/"cache_read_input_tokens"://')
fi

context_window_size=$(echo "$input" | grep -o '"context_window_size":[0-9]*' | sed 's/"context_window_size"://')
# Get cumulative totals for the input/output display
total_input_tokens=$(echo "$input" | grep -o '"total_input_tokens":[0-9]*' | sed 's/"total_input_tokens"://')
total_output_tokens=$(echo "$input" | grep -o '"total_output_tokens":[0-9]*' | sed 's/"total_output_tokens"://')

# Debug: Log all parsed variables
{
  echo "=== PARSED VARIABLES ==="
  echo "model_name: $model_name"
  echo "current_dir_path: $current_dir_path"
  echo "project_name: $project_name"
  echo "used_pct: $used_pct"
  echo "current_usage_block: $current_usage_block"
  echo "current_input: $current_input"
  echo "current_output: $current_output"
  echo "cache_creation: $cache_creation"
  echo "cache_read: $cache_read"
  echo "context_window_size: $context_window_size"
  echo "total_input_tokens: $total_input_tokens"
  echo "total_output_tokens: $total_output_tokens"
  echo ""
} >> "$debug_file"

# Function to format numbers with k suffix (with proper rounding)
format_tokens() {
  local num=$1
  if [ -z "$num" ] || [ "$num" -eq 0 ]; then
    echo "0"
  elif [ "$num" -ge 1000 ]; then
    # Round to nearest thousand: add 500 before dividing
    echo "$(( (num + 500) / 1000 ))k"
  else
    echo "$num"
  fi
}

# Colors (using $'...' for actual escape characters)
CYAN=$'\033[0;36m'         # For model name
MAGENTA=$'\033[0;35m'      # For project name
GREEN=$'\033[0;32m'        # For git branch
YELLOW=$'\033[0;33m'       # For input/output tokens
GRAY=$'\033[0;90m'         # For separator
RESET=$'\033[0m'

# 10-level gradient for progress bar: dark green → deep red
LEVEL_1=$'\033[38;5;22m'   # dark green
LEVEL_2=$'\033[38;5;28m'   # soft green
LEVEL_3=$'\033[38;5;34m'   # medium green
LEVEL_4=$'\033[38;5;100m'  # green-yellowish dark
LEVEL_5=$'\033[38;5;142m'  # olive/yellow-green dark
LEVEL_6=$'\033[38;5;178m'  # muted yellow
LEVEL_7=$'\033[38;5;172m'  # muted yellow-orange
LEVEL_8=$'\033[38;5;166m'  # darker orange
LEVEL_9=$'\033[38;5;160m'  # dark red
LEVEL_10=$'\033[38;5;124m' # deep red

separator="${GRAY} │ ${RESET}"

# 1. Model name with robot emoji
output="${CYAN}🤖 ${model_name}${RESET}"

# 2. Progress bar with hourglass emoji & 3. Percentage (combined)
# Calculate actual token usage from current_usage fields for accurate display
if [ -n "$used_pct" ] && [ -n "$context_window_size" ] && [ "$context_window_size" -gt 0 ]; then
  # Convert percentage to integer
  used_int=$(printf "%.0f" "$used_pct")

  # Calculate actual token count from current_usage fields (more accurate than percentage)
  # Sum all token types: input + output + cache_creation + cache_read
  calc_used=0
  [ -n "$current_input" ] && calc_used=$((calc_used + current_input))
  [ -n "$current_output" ] && calc_used=$((calc_used + current_output))
  [ -n "$cache_creation" ] && calc_used=$((calc_used + cache_creation))
  [ -n "$cache_read" ] && calc_used=$((calc_used + cache_read))

  # Select color based on usage
  if [ "$used_int" -le 10 ]; then
    usage_color="$LEVEL_1"
  elif [ "$used_int" -le 20 ]; then
    usage_color="$LEVEL_2"
  elif [ "$used_int" -le 30 ]; then
    usage_color="$LEVEL_3"
  elif [ "$used_int" -le 40 ]; then
    usage_color="$LEVEL_4"
  elif [ "$used_int" -le 50 ]; then
    usage_color="$LEVEL_5"
  elif [ "$used_int" -le 60 ]; then
    usage_color="$LEVEL_6"
  elif [ "$used_int" -le 70 ]; then
    usage_color="$LEVEL_7"
  elif [ "$used_int" -le 80 ]; then
    usage_color="$LEVEL_8"
  elif [ "$used_int" -le 90 ]; then
    usage_color="$LEVEL_9"
  else
    usage_color="$LEVEL_10"
  fi

  # Build progress bar with [=--------] format
  if [ "$used_int" -eq 0 ]; then
    filled_blocks=0
  elif [ "$used_int" -ge 100 ]; then
    filled_blocks=10
  else
    filled_blocks=$(( (used_int * 10 + 50) / 100 ))
  fi
  [ "$filled_blocks" -lt 0 ] && filled_blocks=0
  [ "$filled_blocks" -gt 10 ] && filled_blocks=10
  empty_blocks=$((10 - filled_blocks))

  progress_bar="["
  i=0
  while [ $i -lt $filled_blocks ]; do
    progress_bar="${progress_bar}="
    i=$((i + 1))
  done
  i=0
  while [ $i -lt $empty_blocks ]; do
    progress_bar="${progress_bar}-"
    i=$((i + 1))
  done
  progress_bar="${progress_bar}]"

  # Format token display using calc_used (already calculated above)
  token_display=""
  if [ "$calc_used" -gt 0 ] && [ -n "$context_window_size" ]; then
    used_formatted=$(format_tokens "$calc_used")
    size_formatted=$(format_tokens "$context_window_size")
    token_display=" ${used_formatted}/${size_formatted} tokens"
  fi

  output="${output}${separator}${usage_color}⏳ ${progress_bar} ${used_int}%${token_display}${RESET}"
fi

# 3.5. Cost estimate (between tokens and git branch)
# Use cumulative session cost from the cost object
total_cost_usd=$(echo "$input" | grep -o '"total_cost_usd":[0-9.]*' | sed 's/"total_cost_usd"://')
if [ -n "$total_cost_usd" ]; then
  # Format cost for display
  if awk "BEGIN {exit !($total_cost_usd < 0.01)}"; then
    cost_display="<\$0.01"
  else
    cost_display=$(awk "BEGIN {printf \"\$%.2f\", $total_cost_usd}")
  fi

  COST_COLOR=$'\033[0;36m'
  output="${output}${separator}${COST_COLOR}💰 ${cost_display}${RESET}"

  {
    echo "=== COST (cumulative session) ==="
    echo "total_cost_usd: \$${total_cost_usd}"
    echo ""
  } >> "$debug_file"
fi

# 4. Git branch with leaf emoji
if git rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -c gc.autodetach=false branch --show-current 2>/dev/null)
  if [ -n "$branch" ]; then
    output="${output}${separator}${GREEN}🌿 ${branch}${RESET}"
  fi
fi

# 5. Project name with folder emoji
output="${output}${separator}${MAGENTA}📁 ${project_name}${RESET}"

# Debug: Log final calculated values
{
  echo "=== FINAL CALCULATED VALUES ==="
  echo "used_int: $used_int"
  echo "calc_used: $calc_used"
  echo "used_formatted: $used_formatted"
  echo "size_formatted: $size_formatted"
  echo "input_formatted: $input_formatted"
  echo "output_formatted: $output_formatted"
  echo ""
  echo "=== FINAL OUTPUT ==="
  echo "$output"
  echo ""
} >> "$debug_file"

# Update session cost CSV on every statusline tick (background, fire-and-forget)
# Pass stable Claude PID so stale sessions can be reaped correctly
echo "$input" | uv run ~/.claude/hooks/log_session_cost.py --live --pid $CLAUDE_PID >>/tmp/claude-sheets-sync.log 2>&1 &

# --- Exit watchdog: marks session "concluded" when Claude Code process dies ---
# Extract session_id from JSON input
_sid=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//;s/"$//')
if [ -n "$_sid" ]; then
  # Use stable CLAUDE_PID for watchdog file and polling
  _wdpf="/tmp/claude-wd-${CLAUDE_PID}.pid"
  _wd_alive=false
  [ -f "$_wdpf" ] && kill -0 "$(cat "$_wdpf" 2>/dev/null)" 2>/dev/null && _wd_alive=true
  if ! $_wd_alive; then
    _stable_pid=$CLAUDE_PID
    (
      # Poll until Claude Code process dies
      while kill -0 "$_stable_pid" 2>/dev/null; do sleep 2; done
      # Process is dead — conclude ALL sessions under this PID
      uv run ~/.claude/hooks/log_session_cost.py --conclude-pid "$_stable_pid" >>/tmp/claude-sheets-sync.log 2>&1
      rm -f "$_wdpf"
    ) &
    echo $! > "$_wdpf"
    disown
  fi
fi

echo "$output"
STATUSLINE_EOF

# Make statusline script executable
chmod +x "$STATUSLINE_SCRIPT"
echo "Created statusline script: $STATUSLINE_SCRIPT"

# Update or create settings.json with statusLine configuration
if [ -f "$SETTINGS_FILE" ]; then
  # Check if python3 is available for JSON manipulation
  if command -v python3 &> /dev/null; then
    # Merge statusLine into existing settings
    python3 << PYTHON_EOF
import json
import sys

settings_file = "$SETTINGS_FILE"
statusline_script = "$STATUSLINE_SCRIPT"

try:
    with open(settings_file, 'r') as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

# Add or update statusLine configuration
settings['statusLine'] = {
    'type': 'command',
    'command': statusline_script
}

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

print(f"Updated existing settings file: {settings_file}")
PYTHON_EOF
  else
    echo "Warning: python3 not found. Cannot safely merge settings."
    echo "Please manually add the following to $SETTINGS_FILE:"
    echo '  "statusLine": {'
    echo '    "type": "command",'
    echo "    \"command\": \"$STATUSLINE_SCRIPT\""
    echo '  }'
    exit 1
  fi
else
  # Create new settings.json
  cat > "$SETTINGS_FILE" << SETTINGS_EOF
{
  "statusLine": {
    "type": "command",
    "command": "$STATUSLINE_SCRIPT"
  }
}
SETTINGS_EOF
  echo "Created settings file: $SETTINGS_FILE"
fi

echo ""
echo "Installation complete!"
echo ""
echo "The statusline displays:"
echo "  🤖 Model name (cyan)"
echo "  ⏳ Context usage progress bar with gradient colors"
echo "  💰 Session cost estimate (cyan)"
echo "  🌿 Git branch (green, if in a repo)"
echo "  📁 Project folder name (magenta)"
echo ""
echo "Session costs are logged to ~/.claude/session-costs.csv"
echo ""
echo "To enable Google Sheets sync, add to your shell config:"
echo "  export CLAUDE_COST_SHEET_ID=\"your-google-sheet-id\""
echo "  export CLAUDE_COST_SA_KEY=\"\$HOME/.config/gcloud/service-account.json\""
echo ""
echo "Restart Claude Code to see the new statusline."
