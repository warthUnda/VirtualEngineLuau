import json
import re
import sys
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[4]
PROTOCOL_VERSION = "2024-11-05"
LONG_BRACKET_RE = re.compile(r"\[(=*)\[")


def _match_long_open(text: str, idx: int) -> int | None:
    m = LONG_BRACKET_RE.match(text, idx)
    return len(m.group(1)) if m else None


def _find_long_close(text: str, start: int, eq_count: int) -> int:
    closing = "]" + ("=" * eq_count) + "]"
    pos = text.find(closing, start)
    return (pos + len(closing)) if pos != -1 else len(text)


def strip_luau_comments(
    source: str,
    keep_directives: bool = True,
    keep_line_numbers: bool = True,
    start_line: int | None = None,
    end_line: int | None = None,
) -> str:
    """Strip Luau comments and blank lines while preserving directives and original line numbers."""
    n = len(source)
    out_chars: list[str] = []
    i = 0
    line_num = 1

    while i < n:
        ch = source[i]

        # String literal: "..." or '...'
        if ch in ('"', "'"):
            quote = ch
            out_chars.append(ch)
            i += 1
            while i < n:
                c = source[i]
                out_chars.append(c)
                if c == "\\" and i + 1 < n:
                    out_chars.append(source[i + 1])
                    if source[i + 1] == "\n":
                        line_num += 1
                    i += 2
                    continue
                if c == "\n":
                    line_num += 1
                i += 1
                if c == quote:
                    break
            continue

        # Backtick interpolated string literal: `...`
        if ch == "`":
            out_chars.append(ch)
            i += 1
            while i < n:
                c = source[i]
                out_chars.append(c)
                if c == "\\" and i + 1 < n:
                    out_chars.append(source[i + 1])
                    if source[i + 1] == "\n":
                        line_num += 1
                    i += 2
                    continue
                if c == "\n":
                    line_num += 1
                i += 1
                if c == "`":
                    break
            continue

        # Long bracket string literal: [[ ... ]] or [=[ ... ]=]
        if ch == "[":
            eq = _match_long_open(source, i)
            if eq is not None:
                end = _find_long_close(source, i + 2 + eq, eq)
                seg = source[i:end]
                out_chars.append(seg)
                line_num += seg.count("\n")
                i = end
                continue

        # Comment: --...
        if ch == "-" and i + 1 < n and source[i + 1] == "-":
            # Directive check (--!strict, --!native, --!optimize 2) at start of line
            if keep_directives and i + 2 < n and source[i + 2] == "!":
                nl = source.find("\n", i)
                end = nl if nl != -1 else n
                out_chars.append(source[i:end])
                i = end
                continue

            # Multi-line block comment: --[[ ... ]] or --[=[ ... ]=]
            if i + 2 < n and source[i + 2] == "[":
                eq = _match_long_open(source, i + 2)
                if eq is not None:
                    end = _find_long_close(source, i + 4 + eq, eq)
                    seg = source[i:end]
                    nl_count = seg.count("\n")
                    out_chars.extend("\n" * nl_count)
                    line_num += nl_count
                    i = end
                    continue

            # Single-line comment
            nl = source.find("\n", i)
            i = nl if nl != -1 else n
            continue

        if ch == "\n":
            line_num += 1
        out_chars.append(ch)
        i += 1

    cleaned_lines = "".join(out_chars).splitlines()
    total_lines = len(cleaned_lines)
    s_idx = max(1, start_line) if start_line is not None else 1
    e_idx = min(total_lines, end_line) if end_line is not None else total_lines

    result_lines: list[str] = []
    for idx in range(s_idx, e_idx + 1):
        raw_line = cleaned_lines[idx - 1].rstrip()
        if not raw_line.strip():
            continue
        if keep_line_numbers:
            result_lines.append(f"{idx}: {raw_line}")
        else:
            result_lines.append(raw_line)

    return "\n".join(result_lines)


def resolve_safe_path(raw_path: str) -> Path:
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        candidate = WORKSPACE_ROOT / candidate
    resolved = candidate.resolve()
    try:
        resolved.relative_to(WORKSPACE_ROOT.resolve())
    except ValueError as exc:
        raise ValueError(f"Path outside workspace is not allowed: {raw_path}") from exc
    norm = str(resolved).replace("\\", "/").lower()
    if (norm.endswith("/skill.md") or norm == "skill.md") and "/.agent/" not in norm and "/.agents/" not in norm:
        raise ValueError("Reading SKILL.md outside .agent/ is blocked by workspace policy.")
    return resolved


TOOLS = [
    {
        "name": "read_compact",
        "description": (
            "Read a workspace source file with blank lines, -- comments, and --[=[ ]=] docblocks stripped "
            "while preserving Luau --! directives and original 1-based line numbers."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "Path": {"type": "string", "description": "Absolute or workspace-relative file path."},
                "StartLine": {"type": "integer", "description": "Optional 1-based inclusive start line."},
                "EndLine": {"type": "integer", "description": "Optional 1-based inclusive end line."},
                "KeepDirectives": {
                    "type": "boolean",
                    "description": "Preserve Luau --! directives (default true).",
                },
                "KeepLineNumbers": {
                    "type": "boolean",
                    "description": "Prefix original 1-based line numbers (default true).",
                },
            },
            "required": ["Path"],
        },
    }
]


def handle_request(req: dict) -> dict | None:
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params") or {}

    if method == "notifications/initialized":
        return None

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "compact-reader", "version": "1.0.0"},
            },
        }

    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}}

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name != "read_compact":
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"isError": True, "content": [{"type": "text", "text": f"Unknown tool: {name}"}]},
            }
        try:
            target = resolve_safe_path(str(args.get("Path", "")))
            text = target.read_text(encoding="utf-8")
            compact = strip_luau_comments(
                text,
                keep_directives=bool(args.get("KeepDirectives", True)),
                keep_line_numbers=bool(args.get("KeepLineNumbers", True)),
                start_line=args.get("StartLine"),
                end_line=args.get("EndLine"),
            )
            return {"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": compact}]}}
        except Exception as exc:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"isError": True, "content": [{"type": "text", "text": str(exc)}]},
            }

    if req_id is None:
        return None
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}


def main() -> None:
    for line in sys.stdin:
        raw = line.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
        except Exception:
            continue
        resp = handle_request(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
