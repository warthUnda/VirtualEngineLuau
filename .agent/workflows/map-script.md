# Workflow: Map Script to Skill

This workflow analyzes a specific script and documents it as a dedicated AI skill inside `.agent/skills/` so future AI agents can understand and work with it without needing to re-read and analyze the entire code file from scratch.

## Steps

1. **Identify the Target Script**:
   - Locate the script specified by the user's argument or mention.
   - If the path is relative or just a file name, locate it in the workspace first.

2. **Ingest and Analyze the Script**:
   - Read the target script using the file-viewing tool.
   - Break down the script into its key components:
     - Remote Events / Functions it listens to or fires.
     - State variables or attributes it reads/updates.
     - Key logic blocks, helper functions, and dependencies.
     - Side effects (e.g., anchoring parts, playing animations, applying damage).

3. **Generate/Update the Skill File**:
   - Create a new directory under `.agent/skills/` named after the script (e.g., `.agent/skills/time-stop-mechanics/` for `TimeStop.server.luau`).
   - Create a `SKILL.md` file in that directory.
   - Use the following template for the `SKILL.md`:

     ```markdown
     ---
     name: [script-name]-mechanics
     description: Architectural map and logic breakdown of the [ScriptName] script. Read this to understand how it handles [core responsibility] and coordinates with other systems.
     ---
     # [ScriptName] Mechanics Map

     ## Overview
     [Brief summary of what the script does and why it exists.]

     ## Key Entry Points & Event Listeners
     - **[Event/Remote Name]**: [What triggers it and what it does]

     ## Core Logic & Functions
     - **[FunctionName]**: [Purpose and return values/effects]

     ## State & Dependencies
     - **State Tracked**: [e.g., PlayerState, attributes, local variables]
     - **Dependencies**: [e.g., SpeedController, ModelMath]

     ## Important Gotchas
     - [Highlight any non-obvious behavior, bugs to avoid, or performance notes]
     ```

4. **Confirm Completion**:
   - Notify the user that the skill has been created/updated and is ready for future models to use.
