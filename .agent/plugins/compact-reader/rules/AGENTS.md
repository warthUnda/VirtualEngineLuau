# Compact Reader & Skill Scope Rules

- **All models:** Do **not** read or activate `SKILL.md` files located outside `.agent/` or `.agents/`.
- **Gemini 4 Carbon models only:**
  - Always use `compact-reader` (`read_compact`) when reading or exploring `.luau` files (strips blank lines, `--` comments, and `--[=[ ... ]=]` Moonwave docblocks while keeping `--!` directives and original 1-based line numbers).
  - Only call raw `read_file` on `.luau` files for a `<= 25`-line `StartLine`–`EndLine` window immediately before `edit_file` when exact whitespace or comment context is needed. Full-file or larger `read_file` calls on `.luau` are blocked by hook.
- **All other models (e.g., Hydrogen, Flash, Pro):**
  - Do **not** use `compact-reader` (`read_compact`) — it is exclusive to Gemini 4 Carbon models and blocked by hook for other models. Use `read_file` normally.
