# Unsheathed

**Unsheathed** is an addon for World of Warcraft: Forever that automatically draws and sheathes your weapons based on movement, combat, and attackable targets. It can help reduce weapon clipping and keep weapons drawn when you want them visible.

Movement always triggers unsheathing. You can choose whether combat and attackable targets trigger it. When draw conditions end, Unsheathed sheathes your weapon after your chosen delay, if automatic sheathing is enabled. The addon ignores dead or ghost targets and avoids drawing during active casts and channels.

Unsheathed also accounts for the client’s weapon-state cycling: `ToggleSheath()` may cycle through melee, ranged, and sheathed states. Ranged weapon changes in combat are left to the client. When configured to use the ranged weapon, the addon can hand off to the main-hand weapon after ranged fire finishes.

**Current version:** 1.1.5

## Features

- Automatically unsheathes when you move.
- Optionally unsheathes during combat or while targeting an attackable enemy.
- Ignores dead or ghost targets.
- Sheathes after a configurable delay when draw conditions end.
- Lets you disable automatic sheathing. With sheathing off, the addon continues to request the selected weapon drawn outside combat.
- Lets you choose between the main-hand and ranged weapon.
- Avoids drawing during active casts and channels.
- Avoids interrupting active Shoot or auto-repeat ranged fire.
- Can switch from a ranged weapon to the main-hand weapon after ranged fire finishes.
- Can pause automatic weapon changes while you are sitting and eating or drinking.
- Saves the enabled state and supported settings separately for each character.

## Installation

### CurseForge

Install Unsheathed using the CurseForge app, or visit the [Project Page](https://www.curseforge.com/wow/addons/unsheathed) directly.

### Manual Installation

1. Download and extract the addon ZIP.
2. Place the `Unsheathed` folder in your WoW AddOns directory. The `.toc` and Lua files should be directly inside that folder, not inside another nested `Unsheathed` folder.
3. Launch the game and enable Unsheathed from the AddOns list if needed.

## Commands

Use `/us` or `/us status` to view the addon’s status and settings. Use `/us help` to display available commands.

| Command | Description |
| --- | --- |
| `/us <on\|off>` | Enable or disable Unsheathed for the current character. |
| `/us sheathe <on\|off>` | Enable or disable automatic sheathing. When off, the addon continues to request the selected weapon drawn outside combat. |
| `/us combat <on\|off>` | Include or ignore combat. When combat is ignored, automatic weapon changes pause until combat ends. |
| `/us target <on\|off>` | Enable or disable target-triggered unsheathing. Dead and ghost targets are ignored. |
| `/us ranged <on\|off>` | Choose the ranged or main-hand weapon. Ranged mode requires a supported class and an equipped ranged weapon. |
| `/us delay <1–60>` | Set the sheathing delay in seconds. Decimals are accepted, for example `/us delay 2.5`. The value is saved per character. |
| `/us help` | Show available commands. |

### Ranged Mode

The WoW client can’t sheath or unsheathe a ranged weapon directly. Switching to the ranged weapon may require the client to cycle through the main-hand weapon first. When Ranged is on, combat weapon changes are left to the client. The addon avoids toggling during active Shoot or auto-repeat fire and can switch to the main hand after a ranged-fire handoff.

## Settings

The default sheathing delay is **3.0 seconds**. Change it for the current character with `/us delay`; the value is saved per character. The Lua default is used when no valid delay has been saved.

These behavior settings can only be changed by editing `Unsheathed.lua`:

- `INCLUDE_JUMPING_AND_FALLING` — Set to `true` to count falling as movement. Default: `false`.
- `WAIT_FOR_MOVEMENT_IN_COMBAT` — Set to `true` to pause automatic weapon draws in combat until movement is detected. When movement starts, a drawn ranged weapon is immediately sheathed before the main hand is drawn; if the weapon is sheathed, the normal draw delay applies. Default: `true`.
- `DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT` — Set to `true` to block automatic weapon transitions after ranged fire in combat until combat ends and the post-Shoot handoff window passes. Default: `false`. This setting is ignored when combat behavior is disabled.

These timing settings can also be changed in `Unsheathed.lua`:

- `COMBAT_DELAY = 0.5` seconds — Delay before drawing a weapon under normal or combat draw conditions.
- `ACTION_DELAY = 1.0` second — Delay after a successful non-Shoot spell causes a possible sheath outside combat.
- `CHAT_DELAY = 3.0` seconds — Delay after your own `/say` or `/yell` message causes a possible sheath.
- `SHEATHE_DELAY = 3.0` seconds — Default delay before automatic sheathing. A valid per-character value set with `/us delay` takes precedence.

## Compatibility

Unsheathed targets the WoW: Forever client with interface version **16001**. The client’s APIs and weapon behavior may differ on other WoW clients or interface versions.

## License

Unsheathed is licensed under **GNU General Public License v3.0 only (GPL-3.0-only)**. See the `LICENSE` file for the complete license text.
