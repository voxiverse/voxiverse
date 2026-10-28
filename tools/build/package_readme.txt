Voxiverse {version}
https://github.com/voxiverse/voxiverse

PLAYING

  Windows: run voxiverse.exe. Windows may say it protected your PC from
  an unknown publisher: the game is not code-signed yet. Choose "More
  info", then "Run anyway".

  Linux: run ./voxiverse. It needs a Vulkan driver (Mesa's or your GPU
  vendor's; most distributions install one) and X11 or XWayland.

  macOS (Apple Silicon): open Voxiverse.app. The app is not from the App
  Store and not notarized, so macOS asks you to confirm the first time:
  right-click it, choose Open, then Open again. Or, in Terminal, in this
  folder: xattr -dr com.apple.quarantine Voxiverse.app
  Vulkan comes inside the app (MoltenVK); nothing else to install.

  Your graphics driver must support Vulkan 1.3.

WHERE YOUR THINGS ARE

  Settings and saves are kept apart from the game, so a newer version can
  replace this folder without losing anything.

  Windows: %LOCALAPPDATA%\voxiverse\settings.cfg
           %LOCALAPPDATA%\voxiverse\saves\
  Linux:   ~/.config/voxiverse/settings.cfg
           ~/.local/share/voxiverse/saves/
  macOS:   ~/Library/Application Support/voxiverse/

  The game's log (voxiverse.log) and screenshots (F2) are written beside
  the game (on macOS, beside Voxiverse.app).

RUNNING A SERVER

  voxiverse-server runs a world with no window for others to join; stop it
  with Ctrl+C (the world is saved). For example:

    voxiverse-server --universe myworld --password secret

  It listens on UDP port 27315; players on your network see it under
  Multiplayer, others join it by its address (Direct Connection). Every
  option: voxiverse-server --help.

  A server and a game of different versions may not play together; each
  says so when joining.

LICENCES

  Voxiverse is MIT licensed: LICENSE. Its fonts are under the SIL Open
  Font License: licenses/.
