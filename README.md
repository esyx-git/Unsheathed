# Unsheathed

**Unsheathed** automatically draws and sheathes your weapons to help prevent weapon clipping during normal movement.

The addon responds to movement, combat, and attackable targets according to your settings. It can also redraw your weapon when an action sheaths it while the conditions for drawing are still met. Unsheathed avoids drawing during active casts and channels.

## Features

- Automatically unsheathes when you move.
- Optionally unsheathes during combat or while targeting a living, attackable entity.
- Sheathes after a configurable delay when movement and attackable targeting stop.
- Optionally prefers the ranged weapon instead of the main-hand weapon.
- Handles the client’s weapon-state cycling between sheathed, melee, and ranged.
- Saves the enabled state and supported settings separately for each character.
- Provides chat commands to check status and change settings.

## Installation

### CurseForge

Install Unsheathed using the CurseForge app, or visit the project page:

**CurseForge:** [Project page](<CURSEFORGE_PROJECT_URL>)

### Manual installation

1. Download and extract the addon ZIP.
2. Place the `Unsheathed` folder in your WoW AddOns directory. The `.toc` and Lua files should be directly inside that folder, not inside another nested `Unsheathed` folder.
3. Launch the game and enable Unsheathed from the AddOns list if needed.

## Commands

Use `/us` or `/us status` to see whether the addon is enabled and the current Combat, Target, Ranged, and Delay settings. Use `/us help` to display the available commands.

| Command | Description |
| --- | --- |
| `/us enable` | Enables Unsheathed for the current character. |
| `/us disable` | Disables Unsheathed for the current character. |
| `/us combat enable` | Allows automatic weapon behavior during combat. |
| `/us combat disable` | Pauses automatic sheathing and unsheathing during combat. |
| `/us target enable` | Allows an attackable target to trigger unsheathing. |
| `/us target disable` | Disables target-triggered unsheathing. |
| `/us ranged enable` | Prefers the ranged weapon when drawing outside combat. |
| `/us ranged disable` | Prefers the main-hand weapon when drawing. |
| `/us delay <1–60>` | Sets the sheathing delay in seconds. Decimal values are accepted, for example `/us delay 2.5`. |

When Ranged is enabled, combat weapon changes are left to the client. Dead or ghost targets do not count as attackable targets.

## Settings

The default sheathing delay is **3 seconds**. Change it for the current character with `/us delay`.

These additional behavior settings are available by editing the Lua file; they cannot be changed through chat commands:

- `INCLUDE_JUMPING_AND_FALLING` — set to `true` to count jumping or falling as movement. Default: `false`.
- `DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT` — set to `true` to block automatic weapon transitions after using a ranged weapon in combat until combat ends and the post-Shoot handoff window passes. Default: `false`. This setting is ignored when Combat is disabled.

The unsheathing and action delays can also be edited in the Lua file. Defaults are `UnsheatheDelay = 0.5` seconds and `ActionDelay = 0.5` seconds.

## Compatibility

Unsheathed targets the WoW: Forever client with interface version **16001**. The client’s APIs and weapon behavior may differ on other WoW clients or interface versions.

## License

Unsheathed is licensed under **GNU General Public License v3.0 only (GPL-3.0-only)**. See the `LICENSE` file for the complete license text.

Replace the following example with your copyright details in the `LICENSE` file:

`Copyright (C) [2026] [Esyx]`

Make sure you have the right to license all files in the repository. Any third-party code or assets may be subject to separate license terms.
