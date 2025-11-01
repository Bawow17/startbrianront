# Brainrot Tanks Architecture

## Project Structure (Rojo)
- `src/ReplicatedStorage/Shared`: stateless modules (`Constants`, `Config`, `MathUtils`, `Collision`, `StatusEffects`, `DataSchemas`). Load by both server and clients.
- `src/ReplicatedStorage/Shared/Components`: component constructors for an ECS-style entity model (`MovementComponent`, `HealthComponent`, `WeaponComponent`, `CosmeticComponent`).
- `src/ReplicatedStorage/Remotes`: `RemoteEvent` and `RemoteFunction` instances packaged by feature (`PlayerInput`, `ProjectileSpawn`, `UpgradePurchase`, `GameState`).
- `src/ReplicatedStorage/Controllers`: thin client-side controller base classes (input, camera, tween effects) reusable across StarterPlayer scripts.
- `src/ServerScriptService/Systems`: server-authoritative systems (`GameLoop`, `TankSystem`, `ProjectileSystem`, `UpgradeSystem`, `SpawnSystem`, `LeaderboardSystem`).
- `src/ServerScriptService/Services`: wrappers around Roblox services (e.g. `PlayerService`, `PhysicsService`, `ProfileServiceAdapter`) to keep dependency boundaries clean.
- `src/ServerStorage/Prefabs`: template `Model` instances for tanks, projectiles, and neutral objects; used by pooling system.
- `src/ServerStorage/DebugTools`: scripts and configs for spawning bots, stress tests, and fast resets.
- `src/StarterPlayer/StarterPlayerScripts/Controllers`: client controllers (`InputController`, `CameraController`, `HUDController`, `PredictionController`).
- `src/StarterPlayer/StarterPlayerScripts/Renderers`: FX and billboard rendering modules decoupled from game logic.
- `src/StarterGui/HUD`: interface assets (`HealthBar`, `XPBar`, `UpgradeMenu`, `Minimap`, `Killfeed`).
- `src/Workspace/Maps`: placeable map segments with tagged spawn regions; exported via Rojo as needed.

## Core Gameplay Modules
- `TankSystem`: manages entity lifecycle; composes components for movement, health, leveling, abilities, cosmetics. Runs server-side tick to process inputs and apply upgrades. Uses shared constants for acceleration/drag limits.
- `ProjectileSystem`: server-authoritative projectile pool. Maintains reusable `BasePart` instances and metadata tables. Updates via spatial partition (quadtree or grid) to batch collision checks and replicate only essential state to clients.
- `UpgradeSystem`: tracks XP, level thresholds, and upgrade trees. Applies stat modifiers by mutating component data and broadcasting deltas to affected clients.
- `AmbientSystem`: drives neutral polygons, bosses, and map hazards. Shares collision utilities with projectiles for consistent damage handling.
- `CosmeticModule`: swaps “brainrot” themed meshes, particle emitters, and sound sets based on tank class or cosmetics purchased.

## Networking Layer
- `RemoteEvent PlayerInput`: clients send sanitized directional input and fire commands at 15–20 Hz. Server validates and feeds into `TankSystem`.
- `RemoteEvent ProjectileSpawn`: server notifies clients of newly spawned projectiles with compressed payload (entity id, type, position, velocity seed).
- `RemoteEvent StateDelta`: server broadcasts batched state changes every tick (position snapshots, health changes, leaderboard slices). Clients reconcile via prediction buffer.
- `RemoteFunction UpgradeRequest`: clients request upgrade purchases; server validates XP and returns success/failure plus new stats.
- Client prediction: `PredictionController` keeps a circular buffer of input history, replays unacknowledged inputs after server reconciliation to minimize jitter.
- Lag compensation: server keeps short history of tank positions (≈250 ms) to resolve projectile hits fairly for higher-latency players.

## Systems & Services
- `GameLoop`: orchestrates tick scheduling, splits logic into fixed update (30/60 Hz) and render update (`Heartbeat` connections) for smoothness.
- `MatchmakingService`: manages 12-player instance cap, auto-balances teams (if any), handles queue entry/exit, and spawns initial tanks.
- `LeaderboardSystem`: aggregates kills, score, survival time; updates HUD via replicated store module.
- `EconomyService`: persists player progress with `DataStoreService`/`ProfileService`, grants XP/coins, records cosmetic unlocks.
- `AnalyticsService`: optional event logging for balancing (hit accuracy, projectile counts per player, ability usage).
- `StarterGui` HUD scripts subscribe to shared `StateStore` module (e.g. Knit or custom signal bus) for reactive UI updates.

## Performance & Tooling
- Utilize `CollectionService` tags to fetch and recycle pooled instances quickly; pair with `ServerStorage/Prefabs` for cloning templates.
- Split projectile updates across frames using job queues to avoid long `Heartbeat` spikes when thousands are active.
- Use `RunService.Heartbeat` for physics-respecting updates and `RunService.Stepped` for deterministic server ticks; throttle replication frequency based on player distance (interest management).
- Add debug commands (`DebugTools/CommandPalette`) for spawning bots, enabling projectile flood, and toggling quadtree overlays.
- Instrument systems with `StatsService`, `MemoryStore`, and custom timers to profile CPU/GPU cost; log top offenders during test sessions.
- Integrate testing harness (e.g. `TestEZ`) in `ServerScriptService/Tests` for deterministic unit tests on component math, collision resolution, and upgrade modifiers.

