#!/bin/bash
# fix_orphaned_tools.sh v2
# Finds and fixes orphaned toolCall entries in OpenClaw .jsonl session files.
# An orphan = a toolUse line whose toolCall blocks don't have a toolResult on the next line.
#
# The fix injects a synthetic toolResult line after the orphaned toolUse line,
# acknowledging each orphaned toolCall with an error message. This restores
# the expected alternating sequence so the API stops rejecting requests.
#
# Usage:
#   ./fix_orphaned_tools.sh --dir <sessions_dir>                          # Dry run (scan only)
#   ./fix_orphaned_tools.sh --dir <sessions_dir> --fix                    # Apply fixes
#   ./fix_orphaned_tools.sh --dir <sessions_dir> --find-id call91455426   # Hunt for a specific call ID
#   ./fix_orphaned_tools.sh --dir <sessions_dir> --truncate 500           # Keep only last N lines
#   ./fix_orphaned_tools.sh --dir <sessions_dir> --fix --max-backups 5    # Limit backup files
#
# Flags:
#   --dir PATH           Path to sessions directory (required)
#   --fix                Apply fixes (default is dry run / scan only)
#   --find-id ID         Hunt for a specific call ID (partial match supported)
#   --truncate N         Keep only last N lines per session file (nuclear option)
#   --warn-lines N       Warn when session files exceed N lines (default: 2000)
#   --max-backups N      Keep only last N backup files per session (default: 3)
#   -h, --help           Show this help message
#
# Examples:
#   ./fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions
#   ./fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions --fix
#   ./fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions --find-id call9145
#   ./fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions --truncate 500
#   ./fix_orphaned_tools.sh --dir ~/.openclaw/agents/ellie/sessions --fix --max-backups 5
#
# macOS and Linux compatible — requires only python3

OPENCLAW_DIR=""
FIX_MODE="false"
FIND_ID=""
TRUNCATE_N=""
WARN_LINES="2000"
MAX_BACKUPS="3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)
            FIX_MODE="true"
            shift
            ;;
        --dir)
            OPENCLAW_DIR="$2"
            shift 2
            ;;
        --find-id)
            FIND_ID="$2"
            shift 2
            ;;
        --truncate)
            TRUNCATE_N="$2"
            shift 2
            ;;
        --warn-lines)
            WARN_LINES="$2"
            shift 2
            ;;
        --max-backups)
            MAX_BACKUPS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --dir <sessions_directory> [options]"
            echo ""
            echo "Scans OpenClaw .jsonl session files for orphaned toolCall entries"
            echo "and optionally injects synthetic toolResult lines to fix them."
            echo ""
            echo "Options:"
            echo "  --dir PATH           Path to sessions directory (required)"
            echo "  --fix                Apply fixes (default is dry run / scan only)"
            echo "  --find-id ID         Hunt for a specific call ID (partial/fuzzy match)"
            echo "  --truncate N         Nuclear option: keep only last N lines per file"
            echo "  --warn-lines N       Warn when files exceed N lines (default: 2000)"
            echo "  --max-backups N      Keep only last N backups per session (default: 3)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --dir ~/.openclaw/agents/ellie/sessions"
            echo "  $0 --dir ~/.openclaw/agents/ellie/sessions --fix"
            echo "  $0 --dir ~/.openclaw/agents/ellie/sessions --find-id call9145"
            echo "  $0 --dir ~/.openclaw/agents/ellie/sessions --truncate 500"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$OPENCLAW_DIR" ]; then
    echo "ERROR: --dir is required. Specify the path to a sessions directory."
    echo "Example: $0 --dir ~/.openclaw/agents/ellie/sessions"
    exit 1
fi

if [ ! -d "$OPENCLAW_DIR" ]; then
    echo "ERROR: Directory not found: $OPENCLAW_DIR"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is required but not found."
    exit 1
fi

echo "=========================================="
echo " OpenClaw Orphaned ToolCall Fixer v2"
echo "=========================================="
echo "Scanning: $OPENCLAW_DIR"
if [ -n "$FIND_ID" ]; then
    echo "Mode: FIND ID (hunting for '$FIND_ID')"
elif [ -n "$TRUNCATE_N" ]; then
    echo "Mode: TRUNCATE (keeping last $TRUNCATE_N lines)"
elif [ "$FIX_MODE" = "true" ]; then
    echo "Mode: FIX (will modify files)"
else
    echo "Mode: DRY RUN (scan only, no changes)"
fi
echo "Warn threshold: $WARN_LINES lines"
echo "Max backups: $MAX_BACKUPS per session"
echo "------------------------------------------"
echo ""

export OPENCLAW_DIR
export FIX_MODE
export FIND_ID
export TRUNCATE_N
export WARN_LINES
export MAX_BACKUPS

python3 << 'PYEOF'
import json
import os
import sys
import shutil
import uuid
import glob
from datetime import datetime, timezone
from pathlib import Path

scan_dir = os.environ.get("OPENCLAW_DIR", "")
fix_mode = os.environ.get("FIX_MODE", "false") == "true"
find_id = os.environ.get("FIND_ID", "")
truncate_n = os.environ.get("TRUNCATE_N", "")
warn_lines = int(os.environ.get("WARN_LINES", "2000"))
max_backups = int(os.environ.get("MAX_BACKUPS", "3"))

if truncate_n:
    truncate_n = int(truncate_n)

if not scan_dir:
    print("No directory specified")
    sys.exit(1)


def rotate_backups(filepath, max_keep):
    """Keep only the most recent N backup files for a given session file."""
    base = str(filepath)
    pattern = f"{base}.bak.*"
    backups = sorted(glob.glob(pattern))
    if len(backups) >= max_keep:
        to_remove = backups[:len(backups) - max_keep + 1]
        for old_bak in to_remove:
            try:
                os.remove(old_bak)
            except OSError:
                pass


def create_backup(filepath):
    """Create a timestamped backup and rotate old backups."""
    rotate_backups(filepath, max_backups)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = f"{filepath}.bak.{timestamp}"
    shutil.copy2(str(filepath), backup_path)
    return backup_path


def extract_all_ids_from_line(raw_line):
    """Extract ALL strings that look like call IDs from a raw line using multiple strategies."""
    import re
    ids = set()

    # Strategy 1: parse JSON and walk toolCall blocks
    stripped = raw_line.strip()
    if stripped:
        try:
            obj = json.loads(stripped)
            msg = obj.get("message", {})
            content = msg.get("content", [])
            for block in content:
                if isinstance(block, dict):
                    bid = block.get("id", "")
                    if bid:
                        ids.add(bid)
                        # Also add the part before the pipe (OpenClaw compound IDs)
                        if "|" in bid:
                            ids.add(bid.split("|")[0])
                            ids.add(bid.split("|")[1])
        except (json.JSONDecodeError, AttributeError):
            pass

    # Strategy 2: regex sweep for any call-like ID patterns in the raw text
    # Matches: call_XXXX, call_12345, callXXXXXXXX, fc_XXXX
    for pattern in [
        r'call_[A-Za-z0-9]{6,}',
        r'call[0-9]{6,}',
        r'fc_[A-Za-z0-9]{20,}',
    ]:
        for match in re.finditer(pattern, raw_line):
            ids.add(match.group())

    return ids


# ─── FIND-ID MODE ─────────────────────────────────────────────
if find_id:
    print(f"🔍 Hunting for call ID matching: '{find_id}'")
    print()

    jsonl_files = list(Path(scan_dir).rglob("*.jsonl"))
    if not jsonl_files:
        print(f"No .jsonl files found in {scan_dir}")
        sys.exit(0)

    total_matches = 0

    for filepath in sorted(jsonl_files):
        with open(filepath) as f:
            lines = f.readlines()

        file_matches = []
        for line_num, raw_line in enumerate(lines, 1):
            # Fuzzy/partial match on raw text
            if find_id in raw_line:
                # Extract context
                all_ids = extract_all_ids_from_line(raw_line)
                matching_ids = [i for i in all_ids if find_id in i]

                # Determine line type
                stripped = raw_line.strip()
                line_type = "unknown"
                role = ""
                stop_reason = ""
                tool_names = []
                try:
                    obj = json.loads(stripped)
                    msg = obj.get("message", {})
                    role = msg.get("role", "")
                    stop_reason = msg.get("stopReason", "")
                    # Check for error messages referencing this ID
                    error_msg = msg.get("errorMessage", "")
                    content = msg.get("content", [])
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "toolCall":
                            tool_names.append(block.get("name", "?"))

                    if error_msg and find_id in error_msg:
                        line_type = "ERROR (API rejection)"
                    elif role == "toolResult":
                        line_type = "toolResult"
                    elif stop_reason == "toolUse":
                        line_type = f"toolUse → tools: {', '.join(tool_names)}"
                    elif role:
                        line_type = f"role={role}"
                except (json.JSONDecodeError, AttributeError):
                    line_type = "unparseable"

                file_matches.append({
                    "line_num": line_num,
                    "line_type": line_type,
                    "matching_ids": matching_ids,
                    "all_ids": list(all_ids)[:5],
                    "role": role,
                    "stop_reason": stop_reason,
                })

        if file_matches:
            total_matches += len(file_matches)
            print(f"📄 {filepath}")
            print(f"   Total lines: {len(lines)}")
            print()

            for m in file_matches:
                icon = "❌" if "ERROR" in m["line_type"] else "⛓" if "toolUse" in m["line_type"] else "📨" if m["role"] == "toolResult" else "📝"
                print(f"   {icon} Line {m['line_num']}: {m['line_type']}")
                if m["matching_ids"]:
                    for mid in m["matching_ids"]:
                        display = mid[:80] + "..." if len(mid) > 80 else mid
                        print(f"      ID: {display}")
                print()

            # Check for orphan: toolUse line with this ID but no toolResult following
            for i, m in enumerate(file_matches):
                if "toolUse" in m["line_type"]:
                    # Look for a toolResult in the next few lines
                    has_result = False
                    for j in range(i + 1, len(file_matches)):
                        if file_matches[j]["role"] == "toolResult":
                            has_result = True
                            break
                        if "toolUse" in file_matches[j]["line_type"]:
                            break  # Another toolUse before a result = orphan
                    if not has_result:
                        print(f"   ⚠️  LIKELY ORPHAN at line {m['line_num']} — no toolResult follows")
                        print(f"       This is probably causing the API rejection.")
                        print()

            print()

    if total_matches == 0:
        print(f"❌ No matches found for '{find_id}' in any session file.")
        print()
        print("Tips:")
        print("  - Try a shorter substring (e.g., --find-id call9145)")
        print("  - The API may be using a transformed version of the ID")
        print("  - Consider using --truncate to cut past the problem")
    else:
        print("==========================================")
        print(f"Found {total_matches} match(es) for '{find_id}'")
        print("==========================================")

    sys.exit(0)


# ─── TRUNCATE MODE ────────────────────────────────────────────
if truncate_n:
    jsonl_files = list(Path(scan_dir).rglob("*.jsonl"))
    if not jsonl_files:
        print(f"No .jsonl files found in {scan_dir}")
        sys.exit(0)

    truncated = 0
    for filepath in sorted(jsonl_files):
        with open(filepath) as f:
            lines = f.readlines()

        if len(lines) <= truncate_n:
            print(f"📄 {filepath.name}: {len(lines)} lines — already under {truncate_n}, skipping")
            continue

        backup_path = create_backup(filepath)

        # Keep only the last N lines
        trimmed = lines[-truncate_n:]
        with open(filepath, "w") as f:
            f.writelines(trimmed)

        truncated += 1
        print(f"✂️  {filepath.name}: {len(lines)} → {len(trimmed)} lines (trimmed {len(lines) - len(trimmed)})")
        print(f"    Backup: {backup_path}")

    print()
    print("==========================================")
    print("SUMMARY")
    print("==========================================")
    print(f"Files truncated: {truncated}")
    if truncated > 0:
        print()
        print(">>> Restart the agent to pick up the trimmed session. <<<")
    else:
        print("All files were already under the threshold.")

    sys.exit(0)


# ─── SCAN / FIX MODE ─────────────────────────────────────────
total_orphans = 0
total_files_with_orphans = 0
fixed_files = 0
oversized_files = []

jsonl_files = list(Path(scan_dir).rglob("*.jsonl"))

if not jsonl_files:
    print(f"No .jsonl files found in {scan_dir}")
    print()
    print("==========================================")
    print("SUMMARY")
    print("==========================================")
    print("No session files to scan.")
    sys.exit(0)

for filepath in sorted(jsonl_files):
    # Read all lines
    lines = []
    with open(filepath) as f:
        for raw_line in f:
            lines.append(raw_line)

    # ─── Session size warning ─────────────────────────────
    if len(lines) > warn_lines:
        oversized_files.append((filepath, len(lines)))

    # Parse each line
    parsed = []
    for i, raw_line in enumerate(lines):
        stripped = raw_line.strip()
        if not stripped:
            parsed.append((i, None, raw_line))
            continue
        try:
            obj = json.loads(stripped)
            parsed.append((i, obj, raw_line))
        except json.JSONDecodeError:
            parsed.append((i, None, raw_line))

    # Find orphaned toolUse lines:
    # A line with stopReason=toolUse where the NEXT parsed line is NOT role=toolResult
    orphans = []  # list of (index_in_parsed, line_num, list_of_toolCall_ids, obj)

    for idx in range(len(parsed)):
        line_num, obj, raw = parsed[idx]
        if obj is None:
            continue

        msg = obj.get("message", {})
        if msg.get("stopReason") != "toolUse":
            continue

        # Collect toolCall IDs from this line — use both structured and regex extraction
        content = msg.get("content", [])
        call_ids = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "toolCall":
                full_id = block.get("id", "")
                name = block.get("name", "unknown")
                call_ids.append((full_id, name))
                # Also track the base ID (before pipe) for compound IDs
                if "|" in full_id:
                    call_ids.append((full_id.split("|")[0], name))

        if not call_ids:
            continue

        # Check if the next non-empty parsed line is a toolResult
        next_obj = None
        for j in range(idx + 1, len(parsed)):
            if parsed[j][1] is not None:
                next_obj = parsed[j][1]
                break

        if next_obj is None:
            orphans.append((idx, line_num, call_ids, obj))
            continue

        next_role = next_obj.get("message", {}).get("role", "")
        if next_role != "toolResult":
            orphans.append((idx, line_num, call_ids, obj))

    if not orphans:
        continue

    total_files_with_orphans += 1
    file_orphan_count = sum(len(calls) for _, _, calls, _ in orphans)
    total_orphans += file_orphan_count

    print(f"FILE: {filepath}")
    print(f"  Lines: {len(lines)}")
    print(f"  Orphaned toolUse lines: {len(orphans)} ({file_orphan_count} total toolCalls)")

    for idx, line_num, call_ids, obj in orphans:
        print(f"  Line {line_num}: {len(call_ids)} toolCall(s) without toolResult")
        for cid, cname in call_ids:
            display_id = cid[:60] + "..." if len(cid) > 60 else cid
            print(f"    - {display_id}  tool={cname}")

    if fix_mode:
        # Create backup with rotation
        backup_path = create_backup(filepath)
        print(f"  Backup: {backup_path}")

        # Build new lines list, injecting synthetic toolResult after each orphan
        new_lines = []
        orphan_indices = {idx for idx, _, _, _ in orphans}
        orphan_map = {idx: (call_ids, obj) for idx, _, call_ids, obj in orphans}

        for idx in range(len(parsed)):
            line_num, obj, raw = parsed[idx]
            new_lines.append(raw)

            if idx in orphan_indices:
                call_ids, parent_obj = orphan_map[idx]

                # Build synthetic toolResult content blocks — one per toolCall
                result_blocks = []
                for cid, cname in call_ids:
                    result_blocks.append({
                        "type": "text",
                        "text": json.dumps({
                            "status": "error",
                            "tool": cname,
                            "error": "Tool call was orphaned - no result was recorded. Synthetic result injected by fix_orphaned_tools.sh v2."
                        })
                    })

                # Get parent ID from the orphaned line
                parent_id = parent_obj.get("id", "") if parent_obj else ""

                synthetic = {
                    "type": "message",
                    "id": uuid.uuid4().hex[:8],
                    "parentId": parent_id,
                    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                    "message": {
                        "role": "toolResult",
                        "content": result_blocks
                    }
                }

                new_lines.append(json.dumps(synthetic) + "\n")
                print(f"  Injected synthetic toolResult after line {line_num} for {len(call_ids)} call(s)")

        # Write the fixed file
        with open(filepath, "w") as f:
            f.writelines(new_lines)

        fixed_files += 1

    print()

# ─── SUMMARY ──────────────────────────────────────────────────
print("==========================================")
print("SUMMARY")
print("==========================================")
print(f"Files scanned: {len(jsonl_files)}")
print(f"Files with orphans: {total_files_with_orphans}")
print(f"Total orphaned toolCalls: {total_orphans}")

if fix_mode:
    print(f"Files fixed: {fixed_files}")
    if fixed_files > 0:
        print()
        print("Backups created with .bak extension. To undo:")
        print("  cp <file>.bak.<timestamp> <file>")
        print()
        print(">>> Restart the agent to pick up the fixed session. <<<")
else:
    if total_orphans > 0:
        print()
        print("Run with --fix to inject synthetic toolResult entries:")
        print(f"  bash fix_orphaned_tools.sh --dir {scan_dir} --fix")
    else:
        print()
        print("✅ No orphaned toolCalls found. Sessions are clean!")

# ─── OVERSIZED FILE WARNINGS ─────────────────────────────────
if oversized_files:
    print()
    print("==========================================")
    print(f"⚠️  OVERSIZED SESSION FILES (>{warn_lines} lines)")
    print("==========================================")
    for fpath, count in oversized_files:
        print(f"  {fpath.name}: {count} lines")
    print()
    print("Large session files are more likely to accumulate orphaned")
    print("tool calls and hit API limits. Consider trimming with:")
    print(f"  bash fix_orphaned_tools.sh --dir {scan_dir} --truncate 500")

# ─── POST-FIX VALIDATION ─────────────────────────────────────
if fix_mode and fixed_files > 0:
    print()
    print("==========================================")
    print("POST-FIX VALIDATION")
    print("==========================================")
    print("If the error persists after fixing and restarting:")
    print("  1. Use --find-id to hunt the specific call ID from the error")
    print(f"     bash fix_orphaned_tools.sh --dir {scan_dir} --find-id <CALL_ID>")
    print("  2. If the ID can't be found, the API may be transforming IDs.")
    print("     Use --truncate as the nuclear option:")
    print(f"     bash fix_orphaned_tools.sh --dir {scan_dir} --truncate 500")
PYEOF
