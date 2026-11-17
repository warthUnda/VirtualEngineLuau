import json
import sys
from pathlib import Path

MAX_CARBON_RAW_LUAU_LINES = 25


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _is_carbon4_model(model_name: str) -> bool:
    lowered = (model_name or "").lower()
    if "carbon" not in lowered:
        return False
    # Match Gemini 4 Carbon variants (e.g. "gemini-4-carbon", "Gemini 4 Carbon (High)", or bare "carbon")
    return "4" in lowered or "gemini" not in lowered


def _is_compact_reader_call(tool_name: str, args: dict) -> bool:
    lowered_tool = tool_name.lower()
    if "compact-reader" in lowered_tool or lowered_tool == "read_compact":
        return True
    if lowered_tool == "call_mcp_tool":
        return "compact-reader" in str(args.get("ServerName") or "").lower()
    return False


def _handle_read_file(args: dict, workspace_paths: list[Path], is_carbon4: bool) -> dict:
    raw_path = args.get("Path") or args.get("path") or ""
    if not isinstance(raw_path, str) or not raw_path.strip():
        return {"decision": "allow"}

    norm = raw_path.replace("\\", "/").lower()
    is_skill_md = norm.endswith("/skill.md") or norm == "skill.md"
    in_agent_dir = (
        "/.agent/" in norm
        or "/.agents/" in norm
        or norm.startswith(".agent/")
        or norm.startswith(".agents/")
    )
    if is_skill_md and not in_agent_dir:
        return {
            "decision": "deny",
            "reason": "Blocked: SKILL.md files outside .agent/ are hidden by workspace policy.",
        }

    if is_carbon4 and norm.endswith(".luau"):
        start_line = args.get("StartLine")
        end_line = args.get("EndLine")
        valid_narrow_slice = (
            isinstance(start_line, int)
            and isinstance(end_line, int)
            and 1 <= start_line <= end_line
            and (end_line - start_line + 1) <= MAX_CARBON_RAW_LUAU_LINES
        )
        if not valid_narrow_slice:
            return {
                "decision": "deny",
                "reason": (
                    "Blocked for Gemini 4 Carbon: always use compact-reader (read_compact) to read .luau files. "
                    f"Raw read_file on .luau is only allowed for <= {MAX_CARBON_RAW_LUAU_LINES}-line "
                    "StartLine..EndLine slices immediately before edit_file."
                ),
            }

    target = Path(raw_path)
    if workspace_paths and target.is_absolute() and not any(_is_within(target, ws) for ws in workspace_paths):
        return {"decision": "ask", "reason": "Reading file outside workspace."}

    return {"decision": "allow"}


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"decision": "ask", "reason": "Could not parse hook payload."}))
        return

    tool_call = payload.get("toolCall") or {}
    tool_name = str(tool_call.get("name") or "")
    args = tool_call.get("args") or {}
    model_name = str(payload.get("modelName") or "")
    is_carbon4 = _is_carbon4_model(model_name)

    if _is_compact_reader_call(tool_name, args):
        if is_carbon4:
            print(json.dumps({"decision": "allow"}))
        else:
            print(
                json.dumps(
                    {
                        "decision": "deny",
                        "reason": (
                            "Blocked: compact-reader is restricted to Gemini 4 Carbon models "
                            f"(current modelName: '{model_name}'). Use read_file instead."
                        ),
                    }
                )
            )
        return

    if tool_name == "read_file":
        workspace_paths = [Path(p) for p in (payload.get("workspacePaths") or []) if isinstance(p, str)]
        print(json.dumps(_handle_read_file(args, workspace_paths, is_carbon4)))
        return

    print(json.dumps({"decision": "allow"}))


if __name__ == "__main__":
    main()
