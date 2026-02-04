#!/bin/bash

# Claude Code Statusline Installer
# Installs custom statusline configuration at the global level (~/.claude)

set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATUSLINE_SCRIPT="$CLAUDE_DIR/statusline.sh"

echo "Installing Claude Code custom statusline..."

# Create .claude directory if it doesn't exist
mkdir -p "$CLAUDE_DIR"

# Create the statusline.sh script
cat > "$STATUSLINE_SCRIPT" << 'STATUSLINE_EOF'
#!/bin/bash

# Read JSON input from stdin
input=$(cat)

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
used_pct=$(echo "$input" | grep -o '"used_percentage":[0-9.]*' | sed 's/"used_percentage"://')

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
echo "  🌿 Git branch (green, if in a repo)"
echo "  📁 Project folder name (magenta)"
echo ""
echo "Restart Claude Code to see the new statusline."
