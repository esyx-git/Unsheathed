# Unsheathed

**Unsheathed** is an addon for World of Warcraft: Forever that automatically draws and sheathes your weapons based on movement, combat, and attackable targets. It can help reduce weapon clipping and keep weapons drawn when you want them visible.

Movement always triggers unsheathing. You can also choose whether combat and attackable targets trigger it. When draw conditions end, Unsheathed sheathes your weapon after your chosen delay, if automatic sheathing is enabled. The addon avoids drawing during active casts and channels, and can redraw your weapon if an action sheathes it while a draw condition is still active.

**Current version:** 1.1.1

## Features

- Automatically unsheathes when you move.
- Optionally unsheathes during combat or while targeting an attackable enemy.
- Sheathes after a configurable delay when draw conditions end.
- Lets you enable or disable automatic sheathing.
- Lets you use your main-hand or ranged weapon.
- Avoids interfering with active Shoot or auto-repeat ranged fire.
- Saves the enabled state and supported settings separately for each character.

## Installation

### CurseForge

Install Unsheathed using the CurseForge app, or visit the [Curseforge Project](https://www.curseforge.com/wow/addons/unsheathed) directly.

### Manual installation

1. Download and extract the addon ZIP.
2. Place the `Unsheathed` folder in your WoW AddOns directory. The `.toc` and Lua files should be directly inside that folder, not inside another nested `Unsheathed` folder.
3. Launch the game and enable Unsheathed from the AddOns list if needed.

## Commands

Use `/us` or `/us status` to view the addon’s status and settings. Use `/us help` to display available commands.

| Command | Description |
| --- | --- |
| `/us <on\|off>` | Enable or disable Unsheathed for the current character. |
| `/us sheathe <on\|off>` | Enable or disable automatic sheathing. |
| `/us combat <on\|off>` | Include or ignore combat. When combat is ignored, automatic weapon changes pause until combat ends. |
| `/us target <on\|off>` | Enable or disable target-triggered unsheathing. |
| `/us ranged <on\|off>` | Choose the ranged or main-hand weapon. Ranged mode requires a supported class and an equipped ranged weapon. |
| `/us delay <1–60>` | Set the sheathing delay in seconds. Decimals are accepted, for example `/us delay 2.5`. |
| `/us help` | Show available commands. |

### Ranged weapon note

The WoW client can’t sheath or unsheathe a ranged weapon directly. Switching to the ranged weapon requires the client to cycle through the main-hand weapon first. When Ranged is on, combat weapon changes are left to the client.

## Settings

The default sheathing delay is **3.0 seconds**. Change it for the current character with `/us delay`; the value is saved per character.

These additional behavior settings can only be changed by editing `Unsheathed.lua`:

- `INCLUDE_JUMPING_AND_FALLING` — Set to `true` to count jumping or falling as movement. Default: `false`.
- `DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT` — Set to `true` to block automatic weapon transitions after ranged fire in combat until combat ends and the post-Shoot handoff window passes. Default: `false`. This setting is ignored when combat behavior is disabled.

The unsheathing and action delays can also be edited in `Unsheathed.lua`:

- `UnsheatheDelay = 0.5` seconds — Delay before drawing a weapon.
- `ActionDelay = 3.0` seconds — Delay after an action, such as speaking, causes the weapon to sheath.

## Compatibility

Unsheathed targets the WoW: Forever client with interface version **16001**. The client’s APIs and weapon behavior may differ on other WoW clients or interface versions.

## License

Unsheathed is licensed under **GNU General Public License v3.0 only (GPL-3.0-only)**. See the `LICENSE` file for the complete license text.
