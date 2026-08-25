# comyudyu P4 Display

Firmware that turns a Guition **JC4880P443C_I_W** (ESP32-P4, 4.3" 480×800
ST7701S) into a USB 2.0 High-Speed display for **SimHub**, with working touch.

## Install

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/comudu/comyudyu-p4-display/main/install.ps1 | iex
```

That is the whole thing. It fetches the latest release, finds the board,
flashes it and starts it. Nothing needs to be installed first — no Python, no
ESP-IDF, no Zadig, no driver.

Options, if you need them:

```powershell
# pick the port yourself
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/comudu/comyudyu-p4-display/main/install.ps1))) -Port COM10

# wipe the factory firmware and its settings first
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/comudu/comyudyu-p4-display/main/install.ps1))) -EraseFlash
```

## Wiring

The board has two USB-C connectors and they are not interchangeable:

| Connector | Use |
|---|---|
| **USB2** (Full Speed) | flashing, and console |
| **USB3** (High speed) | the picture and touch |

Flash over **USB2**. Then plug **USB3** into the PC for the display itself.
Both can be connected at the same time. Use data cables, and a supply that can
deliver more than 600 mA — the vendor's own note asks for this.

## After flashing

The panel cycles test patterns until a host takes over, so you can see straight
away that it works. Plug in USB3, then add the screen in SimHub — Windows binds
the driver by itself.

## What it does

* 480×800 RGB565 over 2-lane MIPI-DSI, panel measured at **60.5 Hz**
* Triple-buffered: a half-received frame is never shown
* **~52 fps / 40 MB/s** ceiling for full uncompressed frames, which is the USB
  2.0 bulk limit on a typical host rather than anything in the firmware
* GT911 touch, single and multi-touch

## Compatibility note

This is an independent implementation. It speaks the same USB protocol as
VoCore's USB screens so that software which already supports them — SimHub in
particular — can drive it without changes, and it presents those screens'
USB VID/PID because that is what such software matches on.

It is **not** a VoCore product, is not affiliated with or endorsed by VoCore,
and contains no VoCore code. The device identifies itself as
`comyudyu P4 Display` everywhere it can. "VoCore" and "SimHub" are the
property of their respective owners and appear here only to describe what this
is compatible with.

## Licence

The installer script is MIT — see [LICENSE](LICENSE).

The firmware binaries link third-party components; their required notices are
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). None of them are copyleft.
