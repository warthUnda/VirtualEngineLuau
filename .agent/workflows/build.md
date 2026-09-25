---
description: Builds the project using Rojo and reports success or failure.
---
# Workflow: Build Project with Rojo

## Steps
1. **Verify Rojo is available**: Run `rojo --version`. If it is not found, report that Rojo is not installed and suggest `rokit add rojo-rbx/rojo` (this project uses Rokit — see `rokit.toml`).
2. **Ensure dependencies are installed**: The `Packages/` and `ServerPackages/` folders are wally-managed and gitignored. If either folder is missing, run:
   ```
   wally install
   ```
   If `wally` is not found, suggest `rokit add UpliftGames/wally` (see `rokit.toml`).
3. **Build the project**: Run the following from the project root (`c:\Users\Startklar\Documents\Development\Roblox\MapGeneration`):
   ```
   rojo build -o "RobloxProjects.rbxlx"
   ```
   Note: Rojo 7.x requires an explicit `--output` (or `--plugin`) flag — a bare `rojo build` will fail.
4. **Check the result**:
   - On success, Rojo prints `Built project to RobloxProjects.rbxlx`. Confirm the `.rbxlx` file was written.
   - On failure, read the error output and report the specific cause (e.g., missing `$path` directory, invalid project JSON).
5. **Report**: Summarize the outcome (success or the exact error) to the user.
