# Free Camera

Press **Insert** to detach the camera from the player and fly it around.

## Install

1. Copy the `FreeCam` folder into your `mods/` directory.
2. Run the build script to compile the native overlay:
   ```bash
   bash modding/mods/FreeCam/build_and_check.sh
   ```
   This stages `FreeCamHelp.dll` into `dist/mods/FreeCam/`.

## Enable

**Whompay Loader:**
- Add `FreeCam` to your `modlist.txt` (one entry per line).

**Manual:**
- Place the `FreeCam` folder in the loader's `mods/` directory.
- The loader will pick it up on next launch.

## Controls

| Key | Action |
|-----|--------|
| **Insert** | Toggle: Off → Fly → Locked → Off |
| **WASD** | Fly forward / back / left / right |
| **Q / E** | Down / Up |
| **Shift** | Fly faster (×4) |
| **Control** | Fly slower (×0.25) |
| **Mouse** | Look around |
| **Mouse Wheel** | Change fly speed |
| **F2** | Freeze / unfreeze world (camera stays free) |
| **F7** | Show / hide on-screen help |

### States
- **Off** — normal third-person camera
- **Fly** — camera detached, WASD + mouse to move
- **Locked** — camera frozen in place; player shoots where the frozen view points

## Settings (mod.ini)

Edit `mod.ini` to change keybinds, speed, look sensitivity, invert Y, pitch limit, or disable the on-screen help. The help text updates automatically from these settings.

## Notes

- The native `FreeCamHelp.dll` is required for the on-screen control list. Without it, the camera still works but nothing is drawn.
- World freeze only works while the free camera is **on**. Turning the camera off always thaws the world.
- Caps Lock works as a hold-to-peek key (camera on while held), but Insert is recommended for toggle behavior.