#!/bin/bash
# Claude Code Notification Setup Script v4
# Global notification hooks with message preview via ntfy.sh

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

HOSTNAME_CLEAN=$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
DEFAULT_TOPIC="claude-jay-${HOSTNAME_CLEAN}"

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Claude Code Notifications Setup (v4 - Global)           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "This script sets up global notification hooks for Claude Code."
echo -e "Notifications are sent via ${YELLOW}ntfy.sh${NC} when:"
echo -e "  ${GREEN}✅ Task Complete${NC}  - Claude finishes a task"
echo -e "  ${YELLOW}⚠️  Input Needed${NC}  - Claude needs your input/permission"
echo

# Prompt for topic
read -p "Notification topic (default: $DEFAULT_TOPIC): " TOPIC
TOPIC=${TOPIC:-$DEFAULT_TOPIC}

# Create global hooks directory
echo -e "\n${GREEN}Creating ~/.claude/hooks directory...${NC}"
mkdir -p ~/.claude/hooks

# Backup existing settings
if [ -f ~/.claude/settings.json ]; then
    BACKUP_FILE=~/.claude/settings.json.bak.$(date +%Y%m%d_%H%M%S)
    cp ~/.claude/settings.json "$BACKUP_FILE"
    echo -e "${YELLOW}Backed up existing settings to ${BACKUP_FILE}${NC}"
fi

# Create the hook script
cat > ~/.claude/hooks/stop_notify.py << 'HOOKSCRIPT'
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["requests"]
# ///
"""Claude Code Hook - Notifications with Message Preview"""

import json, sys, os, argparse, time, socket
from datetime import datetime, timezone, timedelta
from pathlib import Path

NTFY_TOPIC = os.environ.get("CLAUDE_NOTIFY_TOPIC", "claude-code-notify")
NTFY_SERVER = os.environ.get("CLAUDE_NOTIFY_SERVER", "https://ntfy.sh")
ENABLE_NTFY = os.environ.get("CLAUDE_ENABLE_NTFY", "true").lower() == "true"
ENABLE_BELL = os.environ.get("CLAUDE_ENABLE_BELL", "true").lower() == "true"
PREVIEW_LEN = int(os.environ.get("CLAUDE_NOTIFY_PREVIEW_LENGTH", "80"))

# UTC+8 timezone (adjust as needed)
LOCAL_TZ = timezone(timedelta(hours=8))

def truncate(text: str, max_len: int = PREVIEW_LEN) -> str:
    if not text:
        return ""
    text = " ".join(text.split())
    if len(text) <= max_len:
        return text
    return text[:max_len].rsplit(" ", 1)[0] + "..."

def extract_tool_preview(block: dict) -> str:
    """Extract a useful preview from a tool_use block."""
    tool_name = block.get("name", "")
    tool_input = block.get("input", {})

    # AskUserQuestion - extract the question text
    if tool_name == "AskUserQuestion":
        questions = tool_input.get("questions", [])
        if questions and isinstance(questions, list):
            first_q = questions[0]
            if isinstance(first_q, dict):
                return first_q.get("question", "")

    # For other tools, return a description
    if tool_name:
        return f"Needs permission for: {tool_name}"
    return ""

def get_last_text_with_retry(transcript_path: str) -> str:
    """Get last text message after waiting for writes to complete."""
    # Wait for transcript writes to complete
    time.sleep(0.8)

    try:
        path = Path(transcript_path)
        if not path.exists():
            return ""
        with open(path, "r") as f:
            lines = f.readlines()

        # Find the most recent text from assistant entries
        for line in reversed(lines):
            try:
                entry = json.loads(line.strip())
                if entry.get("type") == "assistant":
                    msg = entry.get("message", {})
                    if isinstance(msg, dict):
                        content = msg.get("content", [])
                        if isinstance(content, list):
                            for block in content:
                                if isinstance(block, dict) and block.get("type") == "text":
                                    return block.get("text", "")
            except:
                continue
        return ""
    except:
        return ""

def get_last_message(transcript_path: str, role: str = "assistant", include_tool_use: bool = False) -> str:
    """Get last message of given role from transcript file.

    If include_tool_use is True, also extract content from tool_use blocks
    (e.g., questions from AskUserQuestion) when no text block is found.
    """
    try:
        path = Path(transcript_path)
        if not path.exists():
            return ""
        with open(path, "r") as f:
            lines = f.readlines()

        for line in reversed(lines):
            try:
                entry = json.loads(line.strip())
                if entry.get("type") != role:
                    continue

                msg = entry.get("message", {})
                if not isinstance(msg, dict):
                    if isinstance(msg, str):
                        return msg
                    continue

                content = msg.get("content", [])
                if isinstance(content, str):
                    return content
                if not isinstance(content, list):
                    continue

                # First, look for text blocks
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        text = block.get("text", "")
                        if text:
                            return text

                # If include_tool_use, look for tool_use blocks
                if include_tool_use:
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            preview = extract_tool_preview(block)
                            if preview:
                                return preview
            except:
                continue
        return ""
    except:
        return ""

def send_notification(message: str, title: str, tags: str, priority: str) -> bool:
    try:
        import requests
        return requests.post(
            f"{NTFY_SERVER}/{NTFY_TOPIC}",
            data=message.encode('utf-8'),
            headers={"Title": title, "Tags": tags, "Priority": priority},
            timeout=5
        ).status_code == 200
    except:
        return False

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hook", choices=["stop", "notification"], default="stop")
    args = parser.parse_args()

    try:
        input_data = json.load(sys.stdin)
    except:
        input_data = {}

    transcript_path = input_data.get("transcript_path", "")
    cwd = input_data.get("cwd", "")
    project_name = Path(cwd).name if cwd else "claude"
    hostname_short = socket.gethostname()[:3].lower()
    timestamp = datetime.now(LOCAL_TZ).strftime("%H:%M")

    if args.hook == "notification":
        # Skip idle_prompt - only notify for actual questions/permissions
        notification_type = input_data.get("notification_type", "")
        if notification_type == "idle_prompt":
            sys.exit(0)

        title = "Input Needed"
        tags = "warning,bell"
        priority = "high"

        # Get message from transcript (include tool_use for questions/permissions)
        # Ignore generic "Claude Code needs your attention" from input_data
        claude_msg = get_last_message(transcript_path, "assistant", include_tool_use=True)
        message = truncate(claude_msg) if claude_msg else "Waiting for your input"
    else:
        title = "Task Complete"
        tags = "white_check_mark"
        priority = "default"
        # Retry reading to catch the final text entry
        claude_resp = get_last_text_with_retry(transcript_path) if transcript_path else ""
        if claude_resp:
            message = truncate(claude_resp)
        else:
            user_prompt = get_last_message(transcript_path, "user")
            if user_prompt:
                message = f"Done: {truncate(user_prompt)}"
            else:
                message = "Task finished"

    prefix = f"[{project_name}|{hostname_short}|{timestamp}]"
    message = f"{prefix} {message}"

    if ENABLE_NTFY:
        if send_notification(message, title, tags, priority):
            print(f"Sent: {title}", file=sys.stderr)

    if ENABLE_BELL:
        print("\a", end="", flush=True)
        if args.hook == "notification":
            print("\a", end="", flush=True)

    sys.exit(0)

if __name__ == "__main__":
    main()
HOOKSCRIPT

chmod +x ~/.claude/hooks/stop_notify.py
echo -e "${GREEN}✓ Created ~/.claude/hooks/stop_notify.py${NC}"

# Create or merge settings.json
SETTINGS_FILE=~/.claude/settings.json

if [ -f "$SETTINGS_FILE" ]; then
    # Check if jq is available for merging
    if command -v jq &> /dev/null; then
        echo -e "${GREEN}Merging hooks into existing settings...${NC}"
        HOOKS_JSON='{
          "hooks": {
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "uv run ~/.claude/hooks/stop_notify.py --hook stop"
                  }
                ]
              }
            ],
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "uv run ~/.claude/hooks/stop_notify.py --hook notification"
                  }
                ]
              }
            ]
          }
        }'
        jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(echo "$HOOKS_JSON") > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    else
        echo -e "${YELLOW}jq not found - overwriting settings.json${NC}"
        cat > "$SETTINGS_FILE" << 'SETTINGS'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "uv run ~/.claude/hooks/stop_notify.py --hook stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "uv run ~/.claude/hooks/stop_notify.py --hook notification"
          }
        ]
      }
    ]
  }
}
SETTINGS
    fi
else
    cat > "$SETTINGS_FILE" << 'SETTINGS'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "uv run ~/.claude/hooks/stop_notify.py --hook stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "uv run ~/.claude/hooks/stop_notify.py --hook notification"
          }
        ]
      }
    ]
  }
}
SETTINGS
fi

echo -e "${GREEN}✓ Updated ~/.claude/settings.json${NC}"

# Detect shell config file
if [ -n "$ZSH_VERSION" ] || [ -f ~/.zshrc ]; then
    SHELL_RC=~/.zshrc
else
    SHELL_RC=~/.bashrc
fi

# Add environment variable
echo
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${YELLOW}Step 1:${NC} Add to ${SHELL_RC}:"
echo
echo -e "  export CLAUDE_NOTIFY_TOPIC=\"${TOPIC}\""
echo
echo -e "${YELLOW}Step 2:${NC} Subscribe on your phone/desktop:"
echo
echo -e "  ${CYAN}https://ntfy.sh/${TOPIC}${NC}"
echo
echo -e "${YELLOW}Step 3:${NC} Reload shell or run:"
echo
echo -e "  source ${SHELL_RC}"
echo
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}Optional environment variables:${NC}"
echo -e "  CLAUDE_NOTIFY_TOPIC          Topic name (default: ${DEFAULT_TOPIC})"
echo -e "  CLAUDE_NOTIFY_SERVER         Server URL (default: https://ntfy.sh)"
echo -e "  CLAUDE_NOTIFY_PREVIEW_LENGTH Message length (default: 80)"
echo -e "  CLAUDE_ENABLE_NTFY           Enable ntfy (default: true)"
echo -e "  CLAUDE_ENABLE_BELL           Enable terminal bell (default: true)"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
