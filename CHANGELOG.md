# Changelog

## 1.0.3 - 2026-07-01

- Improved API availability checks so rate limits, timeouts, and server errors are reported as API failures instead of false not-found results.
- Added direct ZIP API probing with `HEAD` plus small ranged GET fallback for sources such as Ryuu.
- Hardened Lua and manifest downloads with operation IDs, curl timeouts/retries, archive listing validation, stale-state failure handling, and real cancel cleanup.

## 1.0.2 - 2026-06-30

- Fixed Community Hub and Add via OpenLuaTools button spacing on Steam store pages.
- Added GitHub issue and feedback templates.
- Added MIT license and security reporting policy.

## 1.0.1 - 2026-06-30

- Removed the Restart Steam button and restart prompt flow for OpenSteamTool.
- Hardened GitHub Releases auto-updates by staging release ZIPs in a temp directory and validating extracted paths before copying files.
- Kept OpenLuaTools focused on OpenSteamTool-only behavior.

## 1.0.0 - 2026-06-24

- Renamed the plugin to OpenLuaTools with the `openluatools` Millennium namespace.
- Ported Lua script install, list, presence, and delete flows to OpenSteamTool's `<Steam>/config/lua` directory.
- Added the bundled OpenLuaTools icon.
- Fixed the header icon fallback so the OpenLuaTools button does not intermittently render a white glyph.
- Added archive validation and temporary extraction safety guards before copying Lua, manifest, and game fix files.
- Reset versioning for the first OpenLuaTools release.
