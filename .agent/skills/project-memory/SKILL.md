---
name: project-memory
description: Local project memory file that provides architectural overview, coding standards, directory structure, and main features of the current project. Read this file to align with the codebase conventions and design decisions.
---
# Project Memory: Roblox Projects

A Roblox procedural terrain, biome generation, and combat system built with Rojo.

## Project Overview

This repository is a Rojo-based Roblox codebase focusing on server-side procedural map and biome generation, state management (combat, speed control, time rewinding/stopping), and client-side actions.

## Core Directory Structure

```
c:\Users\Startklar\Documents\RobloxProjects
├── .agent
│   └── skills
│       ├── combat-client
│       │   └── SKILL.md
│       ├── project-memory
│       │   └── SKILL.md
│       └── speed-controller
│           └── SKILL.md
├── .agents
│   └── rules
│       ├── rule1.md
│       ├── rule2.md
│       ├── rule3.md
│       ├── rule4.md
│       ├── rule5.md
│       └── rule6.md
├── src
│   ├── client
│   │   ├── CameraShake.luau
│   │   ├── Combat
│   │   │   ├── AnimationLoader.luau
│   │   │   └── CombatClient.client.luau
│   │   ├── DesperationCamera.client.luau
│   │   ├── SpeedController
│   │   │   └── SprintController.client.luau
│   │   ├── Thermal
│   │   │   └── ThermalClient.client.luau
│   │   └── TimeStop.client.luau
│   ├── server
│   │   ├── Combat
│   │   │   ├── CombatServer.luau
│   │   │   └── M_Ones
│   │   │       ├── ExecuterM1.server.luau
│   │   │       └── M1HitLogic.luau
│   │   ├── GameState
│   │   │   ├── PlayerState.luau
│   │   │   └── TimeRewind.server.luau
│   │   ├── MapGeneration
│   │   │   ├── BiomeGeneration.luau
│   │   │   ├── ChunkGeneration.luau
│   │   │   ├── MapGenExecuter.luau
│   │   │   └── MapGenerationScript.server.luau
│   │   ├── SpeedController
│   │   │   ├── SpeedController.luau
│   │   │   └── SprintServer.luau
│   │   ├── Thermal
│   │   │   └── ThermalServer.luau
│   │   ├── Hunger
│   │   │   └── HungerServer.luau
│   │   └── TimeStop.server.luau
│   └── shared
│       ├── Math
│       │   └── ModelMath.luau
│       ├── BiomeGenerator.luau
│       ├── Combat
│       │   └── CombatEvents.luau
│       ├── SpeedController
│       │   └── SprintEvents.luau
│       └── Thermal
│           └── ThermalEvents.luau
├── default.project.json
├── rokit.toml
├── selene.Toml
├── wally.toml
└── wally.lock
```

## Key Modules & Components

### Procedural Map & Biome Generation
- [BiomeGenerator.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/shared/BiomeGenerator.luau): Utility for calculating climate (temperature and humidity noise) and determining biomes (Desert, Forest, Jungle, Plains, Tundra, SnowyMountains) at specific coordinates.
- [ChunkGeneration.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/MapGeneration/ChunkGeneration.luau): Procedurally spawns and grows biome cores, moving and locking chunk parts using raycast checks to resolve collisions.
- [MapGenExecuter.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/MapGeneration/MapGenExecuter.luau): Orchestrates map block cloning, sizing, positioning based on Perlin noise heights, and biome color/material applications.
- [BiomeGeneration.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/MapGeneration/BiomeGeneration.luau): Generates terrain using allowed block data (Grassland, Desert, Plains, Mountain, Snow) with Perlin noise heights and height offsets.

### Combat System
- [CombatClient.client.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/client/Combat/CombatClient.client.luau): Client-side directional M1 combat. Captures mouse movement for swing direction ("Left"/"Right"/"Forward"), runs sweep-box hit detection, plays attack animations, fires directional camera shake on hit, and sends AttackHit to server.
- [CombatServer.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/Combat/CombatServer.luau): Server-side hit validation, damage application, blocking attribute check, and hunger consumption. Applies SpeedController debuffs on hit.
- [CombatEvents.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/shared/Combat/CombatEvents.luau): Shared remote events for combat (AttackHit, BlockToggle, M1Normal).
- [CameraShake.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/client/CameraShake.luau): Directional camera shake system with 8 vectors (Left/Right/Up/Bottom + diagonals). Uses RenderStep-bound procedural sine+noise per shake instance.
- [ExecuterM1.server.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/Combat/M_Ones/ExecuterM1.server.luau) / [M1HitLogic.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/Combat/M_Ones/M1HitLogic.luau): Legacy M1 combat logic.

### Speed Controller
- [SpeedController.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/SpeedController/SpeedController.luau): Core module for multiplicative speed buffs/debuffs per player. FIFO removal. Used by SprintServer and CombatServer.
- [SprintServer.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/SpeedController/SprintServer.luau): Sprint stamina system (max 100, drain 20/s, regen 10/s). Applies 2.5x sprint buff via SpeedController. Exposes `ForceSpeedUpdate()` for external debuff application.
- [SprintController.client.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/client/SpeedController/SprintController.client.luau): Client sprint — LeftShift toggle, FOV tween (70↔85), sprint animation, server forced-stop handling.

### Game State
- [PlayerState.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/GameState/PlayerState.luau): Server-side state tracking for players.
- [TimeRewind.server.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/GameState/TimeRewind.server.luau) / [TimeStop.server.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/TimeStop.server.luau): Server mechanics for stopping or rewinding time.

### Thermal & Hunger
- [ThermalServer.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/Thermal/ThermalServer.luau) / [ThermalClient.client.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/client/Thermal/ThermalClient.client.luau): Temperature management system.
- [HungerServer.luau](file:///c:/Users/Startklar/Documents/RobloxProjects/src/server/Hunger/HungerServer.luau): Hunger drain, sprint consumption, and attack consumption.

### Available Skills
- **`.agent/skills/combat-client/SKILL.md`**: Full breakdown of CombatClient directional combat, hit detection, and camera shake.
- **`.agent/skills/speed-controller/SKILL.md`**: Full breakdown of SpeedController, SprintServer, and SprintController.

## Coding Guidelines & Rules
All models BUT gemini flash models and developers MUST adhere to the following rules:
1. **Case Style**: Always write code in **Pascal-Case** ([rule2.md](file:///c:/Users/Startklar/Documents/RobloxProjects/.agents/rules/rule2.md)).
2. **Nesting & Guard Clauses**: Use guard clauses to prevent deep nesting. A maximum of 2 stacked if-then blocks is allowed ([rule1.md](file:///c:/Users/Startklar/Documents/RobloxProjects/.agents/rules/rule1.md)).
3. **Minimal Comments**: Do not use comments unless describing something extremely important. Keep them short, technical, and direct ([rule3.md](file:///c:/Users/Startklar/Documents/RobloxProjects/.agents/rules/rule3.md)).
4. **Scope Control**: Stay strictly within the scope of the active task. Do not preemptively implement future features ([rule5.md](file:///c:/Users/Startklar/Documents/RobloxProjects/.agents/rules/rule5.md)).
5. **Modification Pattern**: Never output unchanged blocks or rewrite entire files. Use targeted diffs or output only the modified parts ([rule4.md](file:///c:/Users/Startklar/Documents/RobloxProjects/.agents/rules/rule4.md)).
6. **Command Confirmation**: Ask for explicit user approval before running database migrations, package modifications, or global configurations ([rule6.md](file:///c:/Users/Startklar/Documents/RobloxProjects/.agents/rules/rule6.md)).
7. **Token Saving**: Ignore `Packages/`, `ServerPackages/`, and generated metadata files (like `sourcemap.json`) when searching or reading codebase context to preserve token limits.


## Setup & Tools
- **Rojo** (7.6.1) for syncing code to Roblox Studio:
  - `src/shared` -> `ReplicatedStorage.Shared`
  - `Packages` -> `ReplicatedStorage.Packages`
  - `src/server` -> `ServerScriptService.Server`
  - `ServerPackages` -> `ServerScriptService.ServerPackages`
  - `src/client` -> `StarterPlayer.StarterPlayerScripts.Client`
- **Rokit** for toolchain management.
- **Wally** (0.3.2) for package management:
  - `promise = "kineticwallet/promise@4.0.0"`
  - `networker = "leifstout/networker@0.3.1"`
  - `profileservice = "firebird702/profileservice@1.1.0"` (server dependency)

## Custom Workflows & Shortcuts
- **`/map-script` [File Path / Mention]**:
  - Whenever the user mentions a file or passes a file path as an argument along with `/map-script`, the model MUST ingest this file argument first.
  - The model then reads the file, analyzes its entry points, logic, state, and dependencies, and maps out every single part of it.
  - Finally, the model creates or updates a dedicated `SKILL.md` file under `.agent/skills/[script-folder-name]/SKILL.md` specifically for that script. This saves tokens and keeps subsequent models from having to re-read the full script from scratch.
