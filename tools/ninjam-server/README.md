# NINJAM server for BandSync Live

BandSync's Live tab uses REAPER's built-in ReaNINJAM, which talks to a NINJAM server. One person (usually
the host, on the machine that stays on) runs the server; everyone connects to its address over Tailscale.

NINJAM is © Cockos, GPL v2: source at https://github.com/justinfrankel/ninjam. Nothing in BandSync links
against it; the server is a separate program.

## Build

- **Windows** (Visual Studio 2019+ Build Tools): clone the repo, copy `build_win.bat` into
  `ninjam/ninjam/server/`, and run it. It produces `ninjamsrv.exe` (built and tested 2026-10-27 with MSVC 14.29).
- **macOS / Linux**: `cd ninjam/ninjam/server && make` (macOS: `make MAC=1`, which needs the Xcode Command Line
  Tools: `xcode-select --install`). Not yet built or tested on a Mac. Only the host needs the server: a Mac
  bandmate connects with REAPER's own ReaNINJAM like everyone else.

## Run

```
ninjamsrv bandsync.cfg
```

`bandsync.cfg` listens on port 2049 and only accepts this machine (127.0.0.0/8) and Tailscale addresses
(100.64.0.0/10), so it isn't open to the internet. Anyone on the band's tailnet can join by name without
a password. Windows asks once whether to let `ninjamsrv.exe` through the firewall: allow it on private networks
(macOS, with its firewall on: "accept incoming network connections", Allow).

Bandmates reach the server through a Tailscale **share** of this machine (admin console > the machine's **...** >
*Share*), so they don't need to join the host's tailnet. Shared-in users arrive from 100.x addresses, which the
ACL above already accepts.

Then, in **BandSync - Panel > Live**, the host enters `<this machine's Tailscale IP>:2049` and clicks
**Save for the band**; everyone else's panel picks the address up from the shared folder.
