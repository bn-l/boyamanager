# BoyaManager

A macOS menu bar app for the **BOYA mini 2** wireless microphone. It shows the
transmitter's battery as bars inside a hollow "B", and one click gives you
everything the receiver reports plus every setting worth changing.

BOYA ships no Mac app for this receiver — the official desktop build only
matches other product ids. This talks to it directly, over the same path an
iPhone uses.

![the menu bar window](docs/popover.png)

## What it does

* **Menu bar icon** — a hollow "B" that fills with up to four battery bars.
  Red when the battery is low, dimmed with no transmitter, struck through when
  the receiver is unplugged.
* **Live status** — receiver battery and charge state, firmware, and per
  transmitter: online, battery, signal and channel.
* **Controls** — noise cancellation, output gain, scene mode, recording mode
  and mute, all bound to the value the device reads back rather than to an
  optimistic local one.
* **Settings** — refresh rate, low-battery threshold, which transmitter the
  icon follows, notifications, launch at login, and the device settings
  (indicator lights, auto power off). Pairing, speaker mode and factory reset
  live behind confirmations in Advanced.
* **Notifications** — low battery, a transmitter connecting or disconnecting,
  the receiver going away.

USB audio is untouched while it runs: nothing is captured or re-enumerated, and
it needs no root.

## Install

```sh
just app          # build BoyaManager.app into ./build
just run          # build and launch
```

Or grab a `.dmg` from Releases. Not sandboxed, hardened runtime, signed with a
local identity.

## How it talks to the receiver

The receiver's settings live behind BOYA's own protocol, **CFD-Link**. On macOS
the only sane route in is the receiver's **iAP interface** (USB interface 1,
class `0xFF`/`0xF0`): no driver binds it, it opens as a normal user, and CFD
frames ride inside an **iAP2 External Accessory session** — exactly what BOYA's
iOS app does.

```
IOUSBHost (interface 1, bulk 0x01/0x81)
  └── iAP2 link  — the accessory initiates; we answer its SYN and identify it
        └── External Accessory session, protocol 177 "BOYA.DeviceLink.com"
              └── CFD-Link frames: heartbeat, get/set attributes on node (1,2,29)
```

Three rules the receiver enforces, each of which cost a day to find:

* **It is mute until heartbeats flow.** Broadcast one every 500 ms and answer
  every one it sends.
* **The router hands your own frames back.** Drop anything whose `src` isn't 1,
  or you answer your own heartbeats forever.
* **The accessory initiates the iAP2 link.** Send your own SYN and it ignores
  you, then re-enumerates itself.

The full protocol, including every attribute and the captures behind them, is
in [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Development

```sh
just gen          # regenerate the Xcode project from project.yml
just app          # build the app bundle
just probe        # handshake with the receiver and dump every attribute
just icons        # render the menu bar icon in every state to /tmp
just log          # follow the app's log stream
swift test        # 124 tests, no hardware needed
```

Command-line flags (`swift run BoyaManager --…`):

| Flag | What |
|---|---|
| `--probe` | Full stack from a terminal: watch, connect, print every attribute, close. Add `--get <attr>` for a direct single read, which shows the status byte. |
| `--render-icons <dir>` | 8× PNGs of the menu bar icon in every state and appearance. |
| `--render-ui <dir>` | Snapshots of the popover and settings. |
| `--dump-log` | Prints the `log stream` command for this app's subsystem. |

### Tests

`swift test` runs everything except the hardware suite, against a scripted
accessory that replays captured bytes and speaks CFD-Link back. With a receiver
plugged in:

```sh
BOYA_HARDWARE=1 swift test --filter HardwareTests
```

That one opens the real interface, round-trips five settings and restores them,
and checks the device is on the same IORegistry entry afterwards — the tell for
an unclean session.

## Requirements

macOS 15+, Apple silicon or Intel. Built with Swift 6.2, strict concurrency, no
third-party dependencies.
