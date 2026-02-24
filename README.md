# Claude Code Notifications & Statusline Setup

Scripts to enhance your Claude Code CLI experience with notifications and a custom statusline.

## Features

### Notifications (`install-notify.sh`)
Get notified via [ntfy.sh](https://ntfy.sh) when:
- **Task Complete** - Claude finishes responding
- **Input Needed** - Claude needs your permission or input

### Custom Statusline (`install-statusline.sh`)
Display a rich statusline showing:
- Model name
- Context window usage (with color gradient)
- Session cost estimate
- Git branch (when in a repo)
- Project folder name

**Example Output:**
```
🤖 Claude Sonnet 4 │ ⏳ [====------] 42% 84k/200k tokens │ 💰 $1.23 │ 🌿 main │ 📁 my-project
```

### Session Cost Tracking
The statusline installer also sets up persistent session cost logging:
- Logs to `~/.claude/session-costs.csv` on every statusline tick
- Syncs to Google Sheets for cross-machine cost visibility
- Tracks session ID, project, model, cost, token usage, and hostname
- PID-based reaping automatically marks stale sessions as "concluded"
- Exit watchdog detects when Claude Code exits and finalizes the session

## Quick Install

```bash
# Install notifications
curl -fsSL https://raw.githubusercontent.com/0xjayfi/notif-statusline-setup/main/install-notify.sh | bash

# Install custom statusline
curl -fsSL https://raw.githubusercontent.com/0xjayfi/notif-statusline-setup/main/install-statusline.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/0xjayfi/notif-statusline-setup.git
cd notif-statusline-setup

# Run either or both
./install-notify.sh
./install-statusline.sh
```

## Post-Install

### Notifications Setup

1. Add to your shell config (`~/.bashrc` or `~/.zshrc`):
   ```bash
   export CLAUDE_NOTIFY_TOPIC="your-unique-topic"
   ```

2. Subscribe to notifications at `https://ntfy.sh/your-unique-topic` or via the [ntfy app](https://ntfy.sh/docs/subscribe/phone/)

3. Reload your shell: `source ~/.bashrc`

### Statusline

Just restart Claude Code - the statusline will appear automatically.

## Configuration

### Notification Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_NOTIFY_TOPIC` | `claude-jay-$hostname` | ntfy topic name |
| `CLAUDE_NOTIFY_SERVER` | `https://ntfy.sh` | ntfy server URL |
| `CLAUDE_NOTIFY_PREVIEW_LENGTH` | `80` | Message preview length |
| `CLAUDE_ENABLE_NTFY` | `true` | Enable/disable ntfy |
| `CLAUDE_ENABLE_BELL` | `true` | Enable/disable terminal bell |

### Google Sheets Cost Tracking

To sync session costs to a Google Sheet across multiple machines:

1. Create a [Google Cloud service account](https://console.cloud.google.com/iam-admin/serviceaccounts) and download the JSON key
2. Enable the **Google Sheets API** in your project
3. Share your Google Sheet with the service account email (Editor access)
4. Add to your shell config:
   ```bash
   export CLAUDE_COST_SHEET_ID="your-google-sheet-id"
   export CLAUDE_COST_SA_KEY="$HOME/.config/gcloud/service-account.json"
   ```

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_COST_SHEET_ID` | *(none)* | Google Sheet ID (from the URL) |
| `CLAUDE_COST_SA_KEY` | *(none)* | Path to service account JSON key |

Live ticks sync at most once per 60 seconds. Session conclude events always sync the full row (including final cost) immediately.

## Requirements

- [uv](https://docs.astral.sh/uv/) - For running the notification hook and session cost logger
- Internet access to ntfy.sh (or self-hosted ntfy server)

## Uninstall

```bash
# Remove notification hook
rm ~/.claude/hooks/stop_notify.py

# Remove statusline script and cost logger
rm ~/.claude/statusline.sh
rm ~/.claude/hooks/log_session_cost.py
rm -f ~/.claude/session-costs.csv
rm -f ~/.claude/session-costs.lock

# Edit ~/.claude/settings.json to remove "hooks" and "statusLine" sections
```

## License

MIT
