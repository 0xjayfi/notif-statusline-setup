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
- Git branch (when in a repo)
- Project folder name

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

## Requirements

- [uv](https://docs.astral.sh/uv/) - For running the notification hook script
- Internet access to ntfy.sh (or self-hosted ntfy server)

## Uninstall

```bash
# Remove notification hook
rm ~/.claude/hooks/stop_notify.py

# Remove statusline script
rm ~/.claude/statusline.sh

# Edit ~/.claude/settings.json to remove "hooks" and "statusLine" sections
```

## License

MIT
