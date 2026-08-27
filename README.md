<p align="center">
  <img src="docs/hero.svg" alt="The menu bar icon filling with battery bars and a dot for the transmitter that comes online" width="420">
</p>

# BoyaManager

A macOS menu bar app for the **BOYA mini 2** wireless mic. It shows the mic battery level in the menu bar and reads and let's you change various settings that are otherwise inaccessible without an app.

BOYA's own application does not support this mic model and is generally pretty terrible. 

<h3 align="center"><a href="#reverse-engineering">Skip to the reverse engineering →</a></h3>

<p align="center">
  <img src="docs/popover.png" alt="The menu bar window" width="330">
</p>

## What it does

Clicking the menu bar icon opens a window containing three things.

`-` The connection state of the receiver (the usb dongle).

`-` One row for each transmitter (the mic) giving its online state, battery level, signal level, charging state and assigned channel.

`-` Controls for noise cancellation, output gain, scene mode, recording mode and mute.

The menubar icon will tell you when the mic's battery is low, when a mic connects or disconnects and when the receiver is unplugged (can all be turned off).

It runs as a normal user and does not require root.

### The menu bar icon

| | State | Meaning |
|:---:|---|---|
| <img src="docs/icon-level.svg" alt="" width="46"> | A transmitter is online | The bars are that transmitter's battery level from 0 to 4. The app draws one dot for each transmitter that is online. |
| <img src="docs/icon-level-two.svg" alt="" width="46"> | Two transmitters are online | The dots say how many transmitters are online and not which ones. The bars show the level of whichever transmitter has less battery remaining. |
| <img src="docs/icon-offline.svg" alt="" width="46"> | No transmitter is online | The receiver is connected and responding and no transmitter is switched on. |
| <img src="docs/icon-connecting.svg" alt="" width="46"> | Connecting | The app is opening a session or waiting to retry after a failure. The icon fades in and out for as long as that lasts. That fade is what separates it from the state where no transmitter is online. |
| <img src="docs/icon-disconnected.svg" alt="" width="46"> | No receiver | No receiver is plugged in. |

## Requirements

`-` The device should be a BOYA mini 2 with USB id `0x2F05:0x003B`. Other BOYA models
may use the same protocol with a different set of attributes but I haven't tested.

`-` macOS 15 or later on Apple silicon.

## Install

There is no release build. Build the app from source:

```sh
brew install just xcodegen
just run          # build BoyaManager.app into ./build and open it
```

`just app` builds the app without opening it and `just dmg` builds a release `.dmg`.
The app bundle and the disk image are both signed with a local development identity
rather than a Developer ID certificate and neither is notarized. A copy carried to
another Mac needs Open Anyway in System Settings › Privacy & Security before it runs.

The app has no Dock icon and no window of its own. Settings › General has a Launch at
login setting.

## Settings

Open the menu bar window and click Settings.

`-` **General** holds the launch at login setting, the notification permission state,
the three notification settings, the version number and a Quit button.

`-` **Device** shows the model, serial number, firmware version, hardware version and
manufacturer the receiver reports, and holds the three settings stored on the
hardware: transmitter indicator lights, transmitter auto power off and receiver auto
power off.

`-` **Advanced** holds the factory reset. It takes two confirmations because it also
clears the transmitter pairings.

Every control takes its value from the receiver rather than from a local copy. A
control is disabled for one round trip after it is changed. The app reports a write
that times out or is refused under the controls.

## Command line

```sh
swift run BoyaManager --probe               # open a session and print every attribute
swift run BoyaManager --probe --get nc      # read one attribute and print its status byte
swift run BoyaManager --render-icons <dir>  # write the menu bar icon in every state at 8×
swift run BoyaManager --render-ui <dir>     # write snapshots of the window and settings
swift run BoyaManager --dump-log            # print the log stream command for the app
```

Quit the app before running `--probe`. Interface 1 is opened exclusively so the claim
fails while the app holds it.

## Reverse engineering

The settings on the receiver are carried by a protocol of BOYA's called **CFD-Link**.
CFD-Link's own word for a setting is attribute and the rest of this section uses that
word. BOYA publishes no description of the protocol. I recovered the description below
from BOYA's own applications and verified it against the receiver.
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) is the full specification with the captures it
was derived from.

### Where the implementation was found

The same SDK ships inside BOYA's Android and iOS applications.

| Application | What it contains |
|---|---|
| **Android APK** | `lib/arm64-v8a/libcfdlink.so` is the SDK built as a shared library with a full symbol table. This is the more useful of the two. |
| **iOS app** | The SDK is statically linked into the binary. The binary is FairPlay encrypted but `LC_ENCRYPTION_INFO_64` gives a `cryptsize` of 4096 bytes so `otool` and `class-dump` read everything past that offset. |

`boyamic.com/support/download` advertises Android version 2.3.4 and serves version
1.1.2. Version 1.1.2 predates the mini 2 and the string "BOYA mini 2" does not appear
anywhere in it. The application's own update endpoint at
`app.release.jiayz.com/appdata/checkAppUpgrade` returns version 2.2.0. That build
contains the class `com.jiayz.device.BoYaMic2AttrId` which holds the attribute table
for this model.

### The frame format

A frame is a sync byte followed by a header, a payload and a checksum.

```
55 | ver/flags | len | seq | src | dst | svc | chid | vid | pid | msg_id | payload | sum
```

Three rules apply. Breaking any of them means the receiver does not answer.

`1.` **The receiver sends no reply until the heartbeat exchange is running.** The host
broadcasts a heartbeat every 500 ms and replies to every heartbeat the receiver sends.
Both continue for the whole session including the intervals spent waiting for a reply.

`2.` **The receiver returns the frames the host sent it.** The host discards every
frame whose `src` field is not 1. Without that check the host replies to its own
heartbeats indefinitely.

`3.` **The attributes are held on a sub-node** rather than on the node that sends the
heartbeats. The host reads the device-describe message from each node and takes the one
with capability bit 2 set. On a mini 2 that node is chid 1, vid 2, pid 29.

A USB packet is not a frame. A `get_all` reply is about 127 bytes and arrives in two
packets, so the host reassembles the byte stream using the length field. Treating each
packet as a frame truncates the attribute list at fourteen entries.

### Reaching the control channel on macOS

Interface 0 is the control channel. It declares itself as a HID interface and does not
implement the HID report model. The firmware treats the two interrupt endpoints as a
raw byte pipe and a CFD frame begins with `0x55`, which is not a declared report id.
The Android application claims interface 0 and calls `bulkTransfer` on it. On macOS I
tried four routes.

`1.` **`hidapi` and `IOHIDDevice`.** IOHIDFamily creates one report handler element for
each report id in the descriptor and discards input that matches none of them. An
incoming frame beginning `0x55` is dropped in the kernel before it reaches the process.

`2.` **`USBInterfaceOpenSeize` through IOUSBLib.** The call returns
`kIOReturnExclusiveAccess` even when run as root because a DriverKit HID driver holds
interface 0.

`3.` **libusb as root.** This works. `libusb_detach_kernel_driver` on macOS captures the
whole device, which detaches the two USB audio interfaces and removes the microphone
from the audio device list for as long as the tool runs. The capture also re-enumerates
the device and invalidates the open handle.

`4.` **Interface 1, the iAP interface.** This is the route the app takes. The interface
has class `0xFF` and subclass `0xF0` and no macOS driver binds to it. `accessoryd`
opens it once at plug-in to run MFi authentication and afterwards holds a user client
without holding the pipe. A claim on interface 1 succeeds as a normal user, captures
nothing, leaves the audio interfaces bound and does not re-enumerate the device.

I found the fourth route from seven undecoded bytes. A CFD heartbeat was visible on the
IN endpoint of interface 1 behind the prefix `e0 14 00 00 00 24 51`. That prefix is the
tail of an iAP2 link packet and the traffic was left over from the receiver's link with
`accessoryd` at plug-in. The receiver runs iAP2 on interface 1 and no process holds
that pipe.

### Implementing the iAP2 host

CFD frames are carried on interface 1 inside an iAP2 External Accessory session under
protocol id 177 and protocol name `BOYA.DeviceLink.com`. This is the transport the iOS
application uses through `EASession`.

```
IOUSBHost (interface 1, bulk 0x01/0x81)
  └── iAP2 link layer
        └── External Accessory session, protocol 177 "BOYA.DeviceLink.com"
              └── CFD-Link frames, identical to the frames on interface 0
```

In iAP2 the receiver is the accessory and the Mac is the host. The accessory opens the
link and the host answers. The accessory sends the six bytes `FF 55 02 00 EE 10` and
the host returns the same six bytes. The accessory then sends a SYN carrying the link
parameters and the session list and the host answers with SYN|ACK. A SYN sent by the
host gets no reply and the accessory re-enumerates itself shortly afterwards.
`IAP2LinkTests` walks a full transcript and asserts that no code path in the app
originates one.

Two further points are worth knowing.

`-` **MFi authentication is the accessory authenticating itself to the host.** A host is
not obliged to request it and this receiver does not require it.

`-` **`ExternalAccessory.framework` cannot be used on macOS** although it ships there and
declares `EASession` from macOS 10.13. `EAAccessoryManager` calls `IAPAppRegisterClient`
in the private `IAP.framework`, which connects to `com.apple.iap2d.xpc` and
`com.apple.iapd.xpc`. Neither daemon exists on macOS and the framework reports zero
accessories. The iAP2 host has to be written directly.

### What the receiver actually implements

The receiver implements 24 attributes. The family table in the Android application
lists 58 attributes because it covers the whole Mic2 range and 33 of those are absent
from a mini 2. The absent ones include the per-transmitter gain attributes and the
whole internal-recorder group. BOYA's published information is wrong in three places.

`-` **Attribute 46, `agc`, does not exist on this model** although BOYA's per-model
metadata lists it. It is absent from the `get_all` reply and a direct read of id 46
returns status 1 whether or not a transmitter is online. `HardwareTests` reads id 46 and
asserts status 1, so a firmware version that starts answering fails a test rather than
passing unnoticed.

`-` **Attributes 63 and 64, `tx1_online` and `tx2_online`, are inverted** with respect to
BOYA's labels. The value 1 means online. A transmitter that is switched off or docked
leaves its battery and signal attributes at their last values rather than dropping them
to zero, so the online attribute is the only reliable indicator of a connection and it
is the only one the app uses.

`-` **Attribute 69, `rx_speaker`, has no description in any BOYA source** and BOYA's
application states only that changing it restarts the device. I measured its effect by
capturing the USB descriptors before and after a write. At value 1 the receiver
publishes one audio streaming interface and the host records from it. At value 0 the
receiver publishes a second class 1 subclass 2 interface which gives the host an
endpoint to send audio to. Adding an interface requires re-enumeration and that is the
restart.

The iOS application has one further guard. For the first ten seconds after the
application connects it refuses to write any frame whose hexadecimal contains
`1e 00 47 01 01`. That sequence writes 1 to attribute 71, `rx_reset`, which is the
factory reset.

## Development

```sh
just gen            # regenerate the Xcode project after adding a file
just app            # build the app bundle
just lint           # SwiftLint, every rule, strict
just ui             # render the window and every settings pane to /tmp
just readme-images  # regenerate the screenshots in docs/ after a UI change
just log            # follow the app's log stream
swift test          # the whole suite, no hardware needed
```

`just readme-images` renders the screenshots in this file rather than anyone capturing
them by hand. The recipe runs `--render-ui`, which draws the window against a fixed
receiver state and follows whichever appearance this Mac is set to.

`swift test` runs against a scripted accessory that replays bytes captured from the
receiver and implements the accessory side of CFD-Link. The frame codec, the session
state machine, the reconnect policy, the view state and the icon are all covered
without hardware. The hardware suite needs a receiver plugged in:

```sh
BOYA_HARDWARE=1 swift test --filter HardwareTests
```

`HardwareTests` opens interface 1, writes and reads back five attributes, restores
their original values and checks that the receiver is on the same IORegistry entry
afterwards. A different entry means the device re-enumerated, which is the indication
that a session was not closed correctly.

The app is written in Swift 6.2 with strict concurrency enabled. It uses `@Observable`
for view state and OSLog for logging and has no third-party dependencies.
[`REPOMAP.md`](REPOMAP.md) describes the source layout.
