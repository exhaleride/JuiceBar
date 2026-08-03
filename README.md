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

- `91%` — battery charge (green while charging, orange ≤ 20 %, red < 10 %)
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

Private APIs can change between macOS releases; everything degrades gracefully
(rows disappear rather than showing garbage). Developed and tested on an
M1 Pro MacBook Pro running macOS 26.

## License

MIT
