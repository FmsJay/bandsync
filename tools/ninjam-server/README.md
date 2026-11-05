# NINJAM server for StudioSync

Play along, Jam and Produce's NINJAM route go through a NINJAM server. It ships with StudioSync (`lib/ninjam`), so nobody
installs or builds anything: the first computer to press Produce or Connect for a song runs it, and the others connect to
it over Tailscale. If that computer's gone, the next one to press takes over. **Host it here** on the Play page moves it by hand.

It listens on port 2049 and only accepts this computer (127.0.0.0/8) and Tailscale addresses (100.64.0.0/10), so it isn't
open to the internet (`lib/ninjam/bandsync.cfg`). Anyone who can reach the computer over Tailscale can join without a
password. Windows or macOS may ask once whether to let it accept connections: allow it.

REAPER's ReaNINJAM plug-in connects to it. ReaNINJAM runs with its window out of sight and its status in StudioSync's panel; **Show it** on
the Play page brings the window up.

It keeps running when REAPER closes, from a copy in StudioSync's own folder (`<resource>/StudioSync/ninjam`), so an update
never has to replace a running program.

NINJAM is © Cockos, GPL v2: source at https://github.com/justinfrankel/ninjam. Nothing in StudioSync links against it;
the server is a separate program.

## Building it (only to update what ships)

From commit `f4c0eff3a1d8d5f3ead470d0c7405c3ee37da24e`:

- **Windows** (Visual Studio 2019+ Build Tools): copy `build_win.bat` into `ninjam/server/` of that repository and run it.
  Put the `ninjamsrv.exe` it makes in `lib/ninjam`.
- **macOS** (Command Line Tools): `sh tools/ninjam-server/build_mac.sh` makes `lib/ninjam/ninjamsrv`, Apple Silicon and Intel.
- **Linux**: `cd ninjam/server && make`, and set its folder as ExtState `ninjam_dir`. Not shipped: StudioSync's installers are Windows and macOS.
