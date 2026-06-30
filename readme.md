# OpenLuaTools for OpenSteamTool

OpenLuaTools is LuaTools for OpenSteamTool.

OpenLuaTools is the OpenSteamTool-compatible continuation of LuaTools as a
Millennium plugin. It targets [OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool)
instead of the legacy SteamTools layout.

## What changed

- Lua scripts are installed, listed, and removed from `<Steam>/config/lua`, which is
  the directory OpenSteamTool watches.
- `setManifestid(...)` lines from downloaded Lua scripts are preserved because
  OpenSteamTool supports manifest pinning.
- Update checks point at `ToxcGang/OpenSteamToolPlugin` and no longer fall back to
  the original upstream package host.
- Auto-updates are distributed through GitHub Releases using the
  `OpenSteamToolPlugin.zip` release asset.
- Downloaded Lua and fix archives are extracted to a temporary plugin directory
  first, then validated before files are copied into Steam or game folders.

## Notes

- This fork is OpenSteamTool-only. It does not write to `<Steam>/config/stplug-in`.
- OpenLuaTools uses the `openluatools` Millennium plugin namespace.
- No automatic migration is performed for old SteamTools `stplug-in` scripts.
