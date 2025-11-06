# Tank Models Setup Guide

## Folder Structure

Place your tank models in `ServerStorage/Prefabs/Tanks/`. Each tank should be a Model directly (not in a subfolder).

## Required Parts in Tank Model

### 1. PlayerPosition (Part)
- **Purpose**: Marks where the player should be positioned relative to the tank center
- **Name**: Must be exactly `"PlayerPosition"`
- **Type**: BasePart (Part, MeshPart, etc.)
- **Position**: Relative to the tank's PrimaryPart
- **Note**: This part will be automatically hidden (transparency = 1)

### 2. Barrel (Part/Model)
- **Purpose**: Marks where projectiles should spawn from and defines the barrel visual
- **Name**: Must be exactly `"Barrel"`
- **Type**: BasePart (Part, MeshPart) or Model containing barrel mesh
- **Position**: Relative to the tank's PrimaryPart
- **Note**: 
  - You can have multiple parts/models named "Barrel" for multi-barrel tanks (they will all be detected)
  - Barrel parts remain visible - they are part of the tank model
  - For future upgrades, you can duplicate barrel parts to add more barrels

## Model Setup

1. Create your tank model in Roblox Studio
2. Set the **PrimaryPart** of your Model (this is the center reference point)
3. Add a **PlayerPosition** part where you want the player to sit (this will be hidden)
4. Add one or more **Barrel** parts/models where projectiles should spawn (these stay visible)
5. Place the model in `ServerStorage/Prefabs/Tanks/` with a descriptive name (e.g., "ToyTank", "HeavyTank")

## Example Usage

When spawning a tank, specify the tank type:

```lua
TankSystem.spawnTankRecord(player, {
    tankType = "ToyTank",  -- Name of the model in ServerStorage/Prefabs/Tanks/
    animationId = "rbxassetid://123456789",  -- Optional animation for player pose
})
```

## Notes

- The PlayerPosition part will be automatically hidden (transparency = 1)
- Barrel parts/models remain visible as part of the tank model
- The tank model will be cloned for each player
- The player offset is calculated from the tank's PrimaryPart to the PlayerPosition part
- Barrel positions are calculated relative to the tank's PrimaryPart
- The barrel system is designed to support future upgrades where barrels can be duplicated
