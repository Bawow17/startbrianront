# Rojo Model Preservation Guide

## Problem
Rojo deletes models created directly in Roblox Studio when they're not defined as files in your project.

## Solution: Partially Managed Folders

For folders that contain **Studio-created models** (not files), you should:

### 1. Define the folder structure WITHOUT `$path`

When a folder has `$path`, Rojo tries to sync files from that directory. If models are created in Studio (not files), Rojo will delete them.

**Correct Configuration:**
```json
{
  "ServerStorage": {
    "$className": "ServerStorage",
    "$ignoreUnknownInstances": true,
    "Prefabs": {
      "$className": "Folder",
      "$ignoreUnknownInstances": true,
      "Tanks": {
        "$className": "Folder",
        "$ignoreUnknownInstances": true
      }
    }
  }
}
```

**Incorrect Configuration (will delete models):**
```json
{
  "ServerStorage": {
    "$className": "ServerStorage",
    "$ignoreUnknownInstances": true,
    "$path": "src/ServerStorage",  // ❌ Don't use $path for folders with Studio models
    "Prefabs": {
      "$className": "Folder",
      "$path": "src/ServerStorage/Prefabs"  // ❌ This will cause Rojo to sync files
    }
  }
}
```

### 2. Set `$ignoreUnknownInstances: true`

This tells Rojo to preserve any instances (models) that aren't defined in your project file.

### 3. Optional: Add `init.meta.json` files

You can add `init.meta.json` files in folders for extra protection:

**`src/ServerStorage/Prefabs/Tanks/init.meta.json`:**
```json
{
  "$ignoreUnknownInstances": true
}
```

## Key Principles

1. **Folders with Studio-created models**: Define structure WITHOUT `$path`
2. **Folders with files to sync**: Define structure WITH `$path`
3. **Always set `$ignoreUnknownInstances: true`** for folders containing Studio models

## Example: Mixed Setup

If you have both files AND Studio models:

```json
{
  "ServerStorage": {
    "$className": "ServerStorage",
    "$ignoreUnknownInstances": true,
    "Prefabs": {
      "$className": "Folder",
      "$ignoreUnknownInstances": true,
      "Tanks": {
        "$className": "Folder",
        "$ignoreUnknownInstances": true
        // No $path = Studio models preserved
      }
    },
    "Scripts": {
      "$className": "Folder",
      "$path": "src/ServerStorage/Scripts"
      // Has $path = Files synced from filesystem
    }
  }
}
```

## Current Project Configuration

Your `default.project.json` is now configured correctly:

- `ServerStorage` has `$ignoreUnknownInstances: true` and NO `$path`
- `Prefabs` has `$ignoreUnknownInstances: true` and NO `$path`
- `Tanks` has `$ignoreUnknownInstances: true` and NO `$path`

This means:
- ✅ Rojo will preserve models created in Studio under `ServerStorage.Prefabs.Tanks`
- ✅ Rojo will NOT try to sync files from `src/ServerStorage/Prefabs/Tanks`
- ✅ Models like `ToyTank` will be preserved when reconnecting Rojo

## References

- [Rojo Documentation](https://rojo.space/docs)
- [Fully vs Partially Managed Projects](https://rojo.space/docs/v0.5/reference/full-vs-partial/)

