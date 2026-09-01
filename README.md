# JuiceBar 🧃

A tiny native macOS menu bar app that shows your Mac's live **energy balance** —
what comes in from the wall, what the system burns, and what flows in or out of
the battery — plus temperatures, fans, and throttle detection.

Built for Apple Silicon MacBooks. No Electron, no dependencies, no Xcode
project — one `swiftc` call.

## Menu bar

```
91% +15 ⌁78
```

- `91%` — battery charge (green while charging, **blue while held at the charge
  limit**, orange ≤ 20 %, red < 10 %)
- `+15` — net watts into (+) or out of (−) the battery
- `⌁78` — watts arriving from the wall (hidden on battery)
- `⚠︎` — appears only when the SoC is genuinely throttling

## Dropdown

- **IN / OUT / NET** — wall power (with the negotiated USB-PD contract),
  system draw broken into CPU / GPU / ANE / Rest, and battery flow with
  time-to-full/empty
- **Rest sub-consumers** — anything identifiable drawing > 4 W gets its own
  row: measured on-chip meters (memory, media engine, camera ISP, PCIe) plus a
  display-backlight estimate
- **NETWORK** — live down/up rates (physical interfaces only; VPN traffic is
  not double-counted)
- **THROTTLE** — per-cluster frequency vs. max with busy %, so DVFS idle
  clocking isn't mistaken for thermal throttling
- **TEMPS / FANS** — curated hot spots + an all-sensors submenu, fan RPM
- **SYS** — display brightness (≈ nits), RAM + memory pressure, swap usage,
  and SSD fill level
- **CHARGE LIMIT** — cap charging at 80 / 85 / 90 / 95 %, or 100 % for no limit,
  with a status line saying what the battery is actually doing (`held at 80 %`,
  `charging to 85 %`, `above 80 % — draining to it`). Replaces AlDente.

## Install

```sh
./build.sh
```

Compiles, ad-hoc signs, installs to `~/Applications/JuiceBar.app`, and launches.
Registers itself as a login item.

## How it reads the numbers

- Wall/adapter/battery: `AppleSmartBattery` via IOKit (wall telemetry refreshes
  ~every 30 s — the app shows "settling…" after (un)plugging instead of stale numbers)
- SoC power & frequencies: Apple's private `IOReport` API (no root needed),
  channel handling modeled on [macmon](https://github.com/vladkens/macmon)
- Temperatures: HID sensor services; fans: SMC
- Display brightness: `DisplayServicesGetBrightness` (macOS exposes no live
  measured nits to userspace — nits and backlight watts are estimates)
- Charge limit: drives **macOS's own limiter** — the same setting as System
  Settings › Battery › Charge Limit — through the private `PowerUI` framework
  and the `PowerUIAgent` XPC service. No root, no SMC writes, no privileged
  helper, no admin password. Needs a Mac that offers Charge Limit (Apple
  silicon, macOS 26+); elsewhere the section simply doesn't appear.

### Notes on the charge limit

Two things about that API were found by measurement, not documentation:

- `setMCLLimit:` reports success and changes nothing. The setter that works is
  `temporarilyOverrideMCLTargetSoC:`.
- The chosen cap is held **in PowerUIAgent's memory only** — nothing lands on
  disk — so macOS forgets it when that daemon restarts or the Mac reboots.
  JuiceBar therefore remembers your choice itself and re-applies it on launch
  and whenever it notices the two have drifted apart.

Because of that, **JuiceBar owns the setting**: change the cap here rather than
in System Settings, or JuiceBar will put its own value back within a minute. On
first launch it adopts whatever macOS is already doing, so nothing changes
until you pick a value.

The old third-party approach — a root helper writing SMC keys `CH0B`/`CH0C`/
`BCLM` — is dead on this hardware: those keys no longer exist in the SMC.

**Deliberately not built.** AlDente's discharge-to-X, heat protection, calibration
and sailing modes have no equivalent in Apple's API — there is nothing to call.
A "charge to 100 % once" button (`temporarilyEnableCharging:`) is one selector
away and would be genuinely useful, but it was left out of 1.1 because its
effect is only observable on mains power and the machine was on battery when
this shipped — an unverified button is worse than a missing one. Verify it
against `ioreg … IsCharging` before adding it.

Private APIs can change between macOS releases; everything degrades gracefully
(rows disappear rather than showing garbage). Developed and tested on an
M1 Pro MacBook Pro running macOS 26.

## License

MIT
