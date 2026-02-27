# 🦞 OpenClaw Fix Orphaned Tools

A diagnostic and repair utility for [OpenClaw](https://openclaw.io) session files. Fixes the dreaded `tool_use ids were found without tool_result blocks` error that occurs when an agent crashes mid-tool-call, leaving orphaned `toolCall` entries in `.jsonl` session files.

## The Problem

When an OpenClaw agent crashes, loses connection, or times out during a tool call, the session file ends up with a `toolCall` block that never received a matching `toolResult`. The next time the agent tries to send the conversation history to the LLM API, the request is rejected:

```
LLM request rejected: messages.449: tool_use ids were found without tool_result blocks
immediately after: call91455426. Each tool_use block must have a corresponding
tool_result block in the next message.
```

The agent is now stuck — every request fails with the same error, and the only way to recover is to manually edit the session file or delete it entirely (losing all context).

This script automates the fix.

## Installation

```bash
# Clone the repo
git clone https://github.com/jrodriguezjr/openclaw-fix-orphaned-tools.git
cd openclaw-fix-orphaned-tools

# Make it executable
chmod +x fix_orphaned_tools.sh

# Optional: symlink to your PATH for easy access
ln -s "$(pwd)/fix_orphaned_tools.sh" /usr/local/bin/fix-orphaned-tools
```

### Requirements

- `python3` (macOS and most Linux distros have this pre-installed)
- No additional Python packages required

## Usage

### Scan for Problems (Dry Run)

Always start here. Scans session files and reports orphaned tool calls without modifying anything:

```bash
bash fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions
```

### Fix Orphaned Tool Calls

Injects synthetic `toolResult` entries after each orphaned `toolCall`, restoring the expected alternating sequence:

```bash
bash fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions --fix
```

Backups are created automatically before any modifications (`.bak.<timestamp>` files).

### Hunt for a Specific Call ID

When the API error references a specific call ID, use `--find-id` to locate it. Supports partial/fuzzy matching:

```bash
bash fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions --find-id call9145
```

This is useful when `--fix` patches orphans but the error persists — the problematic call ID may be in a format the standard scan doesn't catch (compound IDs, transformed IDs, etc.).

### Truncate Oversized Sessions (Nuclear Option)

When patching doesn't work or a session file has grown too large, truncate it to keep only the most recent N lines:

```bash
bash fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions --truncate 500
```

This drops old conversation history but guarantees a clean session.

### Additional Options

```bash
# Adjust the oversized file warning threshold (default: 2000 lines)
bash fix_orphaned_tools.sh --dir <path> --warn-lines 3000

# Limit backup file accumulation (default: keeps last 3)
bash fix_orphaned_tools.sh --dir <path> --fix --max-backups 5

# Show all options
bash fix_orphaned_tools.sh --help
```

## Recommended Workflow

When you see the `tool_use ids were found without tool_result blocks` error:

```
1. Scan        →  bash fix_orphaned_tools.sh --dir <sessions> 
2. Fix         →  bash fix_orphaned_tools.sh --dir <sessions> --fix
3. Restart     →  openclaw gateway restart
4. Still broken? → bash fix_orphaned_tools.sh --dir <sessions> --find-id <ID_FROM_ERROR>
5. Still broken? → bash fix_orphaned_tools.sh --dir <sessions> --truncate 500
6. Restart     →  openclaw gateway restart
```

## How It Works

### Scan / Fix Mode

1. Reads each `.jsonl` session file line by line
2. Identifies lines where `stopReason` is `"toolUse"` (the agent made a tool call)
3. Checks if the next non-empty line has `role: "toolResult"` (the expected response)
4. If no `toolResult` follows, the tool call is orphaned
5. In fix mode, injects a synthetic `toolResult` line acknowledging the failure:

```json
{
  "type": "message",
  "id": "<generated>",
  "parentId": "<orphaned_message_id>",
  "timestamp": "<current_time>",
  "message": {
    "role": "toolResult",
    "content": [{
      "type": "text",
      "text": "{\"status\":\"error\",\"tool\":\"session_status\",\"error\":\"Tool call was orphaned...\"}"
    }]
  }
}
```

### Find-ID Mode

Uses both structured JSON parsing and regex sweeps to locate call IDs across session files. Handles:

- Standard IDs: `call_XXXXX`
- Numeric IDs: `call12345678`
- Compound IDs: `call_XXX|fc_YYY` (splits and searches both halves)
- Partial matches: `--find-id call9145` matches `call91455426`

### Truncate Mode

Keeps only the last N lines of each session file, discarding old history. Useful when:

- Session files grow to thousands of lines
- The orphaned call is buried deep in history and can't be found
- You want a clean slate without deleting the session entirely

## Compatibility

- **macOS** (Apple Silicon and Intel)
- **Linux** (Ubuntu, Debian, etc.)
- **OpenClaw** 2026.2.x+ (`.jsonl` session format)

## License

MIT License — see [LICENSE](LICENSE) for details.

## Contributing

Issues and PRs welcome. If you encounter a session format or error pattern this script doesn't handle, open an issue with a sanitized example and we'll add support for it.

## Author

**Joe Rodriguez** — [github.com/jrodriguezjr](https://github.com/jrodriguezjr)

Built out of necessity after one too many 2 AM OpenClaw crashes.
