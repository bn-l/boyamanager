# BOYA mini 2 — Receiver Control Protocol ("CFD-Link")

A complete description of how BOYA Central talks to a **BOYA mini 2** receiver over
USB, reverse-engineered from the iOS app, the Android app, the macOS desktop app and
the device itself. Everything here has been verified against real hardware unless
explicitly marked as unverified.

Target device: **BOYA mini 2 RX**, USB `0x2F05:0x003B`
("Shenzhen jiayz photo industrial ltd").

---

## 1. TL;DR

* The receiver's settings live behind a proprietary protocol called **CFD-Link**,
  carried as raw frames on a **vendor USB interface** (interface 0, interrupt
  endpoints `0x02` OUT / `0x82` IN, 64-byte packets).
* Interface 0 *declares itself as HID*, but the protocol **ignores HID entirely** —
  no report IDs, just raw bytes on the interrupt endpoints. The Android app claims
  the interface and does `bulkTransfer`.
* A frame is `55 | 1X | len | seq | src | dst | svc | chid | vid | pid | msg_id |
  payload | checksum`.
* The device is **mute until you heartbeat it**, and settings live on a *sub-node*
  of the link, not on the first node that answers.
* A mini 2 exposes **25 attributes** — see **§9.5**, which is the definitive list for
  this model. The settable ones are noise cancellation (47, `0..2`), output gain
  (65, `1..6`), scene mode (41 — this is where low cut lives), recording mode
  (68 — Mono/Stereo/Safety Channel), mute (48) and AGC (46).
* The APK's family-wide attribute table lists 58 ids; **33 of them do not exist on a
  mini 2** (§9.6) — including per-TX gain and everything to do with an internal
  recorder.
* On macOS, **don't fight interface 0 at all**. The receiver's *iAP interface*
  (interface 1, bulk `0x01`/`0x81`) has no driver, claims as a normal user without
  capturing the device, and carries the very same CFD frames inside an **iAP2
  External-Accessory session** — the iPhone's path. No root, and the USB audio
  keeps working. See §10 and §13. (Interface 0 still works via libusb's
  whole-device capture, but that needs root and drops the mic off the audio
  device list while the tool runs.)
* The `svc` field does **not** matter (`0x1B`, `0x1D`, `0x1E`, `0x00` all work);
  what matters is `src != 1`. See §4.2.

Working implementation: [`boyactl.py`](./boyactl.py) (iAP2 transport in
[`scripts/iap2.py`](./scripts/iap2.py)).

---

## 2. USB layout of the receiver

```
BOYA mini 2  —  idVendor 0x2F05, idProduct 0x003B, bcdUSB 1.10, 1 configuration
├── Interface 0   class 3 (HID), subclass 0, protocol 0     ← control channel
│     EP 0x82  interrupt IN,  wMaxPacketSize 64
│     EP 0x02  interrupt OUT, wMaxPacketSize 64
├── Interface 1   class 0xFF, subclass 0xF0  "iAP Interface" ← MFi / iAP2 — the macOS path (§10, §13)
│     EP 0x81  bulk IN,   wMaxPacketSize 64
│     EP 0x01  bulk OUT,  wMaxPacketSize 64
├── Interface 2   class 1, subclass 1   USB Audio Control
└── Interface 3   class 1, subclass 2   USB Audio Streaming (2ch in, 48 kHz)
```

macOS also reports `"Authenticated" = Yes` and `"iAPAuthenticator" = "accessoryd"`
for this device — it carries an MFi authentication coprocessor for the iOS path.

### 2.1 HID report descriptor (interface 0)

231 bytes. Decoded, it contains four collections:

| Usage page | Report ID | Contents |
|---|---|---|
| `0x0C` Consumer | 6 | volume/mute/transport keys (8 bits in) |
| `0x0B` Telephony | 7 | hook switch, phone mute, LED outputs |
| `0xFF90` vendor | 3 | 63-byte Input (buffered), 63-byte Output (**constant**) |
| `0xFF82` vendor | 0x41 | 63-byte Input, 63-byte Output (both Data,Var,Abs) |

Raw:

```
050c0901a10185061500250109e909ea09e209cd09b509b609b109b7750195088142750195088103c0
050b0901a101850715002501092009977501950281237506950181030921092f09507501950381070906
a10219b029bb1500250c750495018140c0090705097501950181020508150025010908091709180919
091a091e091f09200921092209230924092509260909750195 0f9102750195019103c0
0690ff0901a10109038503150026ff007508953f8202010904150025017508953f9101c0
0682ff0901a10109038541150026ff007508953f81020904150026ff007508953f9102c0
```

**These vendor collections are a red herring.** The firmware does not implement the
HID report model on them — it treats the interrupt endpoints as a raw byte pipe.
CFD frames begin with `0x55`, which is not a declared report ID, and no amount of
`SET_REPORT`/`GET_REPORT` from a HID API will get you a reply (verified: 48 node
addresses × both vendor collections × several framings × correct heartbeats = zero
responses). You must talk to the endpoints directly.

---

## 3. Where the protocol implementation lives

| Artefact | What it gives you |
|---|---|
| **iOS** `BOYA Central.app` (`com.boya.eco`, v2.3.3, arm64) | Whole SDK statically linked. FairPlay-encrypted but `LC_ENCRYPTION_INFO_64` has `cryptsize 4096` only, so `otool`/class-dump work fine. Objective-C class `CFDLinkTool` is the app-side wrapper. |
| **Android** APK `com.boya.eco` | **Best source.** `lib/arm64-v8a/libcfdlink.so` is the same SDK as a shared library **with a full symbol table**. Java in `com.jiayz.device.*` shows the transport and the attribute-ID tables. |
| **macOS** `BOYA Central.pkg` v1.1.1 | Qt app using `libhidapi`, classes `HIDDevice`/`hidProtocol`/`HIDHotplugManager`. **Does not support the mini 2** — it only matches USB `0x2F05:0x1396` and `0x3327:*`. |

### 3.1 Getting a *current* Android APK

The download page at `boyamic.com/support/download` advertises "Android v2.3.4" but
the link serves **`BOYA_Central_V1.1.2_full_release.apk`**, which predates the mini 2
entirely (no "BOYA mini 2" string anywhere in it). Ask the app's own updater instead:

```sh
curl -s -X POST https://app.release.jiayz.com/appdata/checkAppUpgrade \
     -H 'Content-Type: application/json' \
     -d '{"appName":"BOYA","appVersion":"V1.1.2","systemName":"Android","languageType":"1"}'
# -> data.newVersionApkUrl  (v2.2.0 at time of writing)
```

v2.2.0 contains `com.jiayz.device.BoYaMic2AttrId` — the authoritative attribute table.

### 3.2 Useful symbols in `libcfdlink.so`

Addresses below are from the **arm64-v8a build shipped in APK 1.1.2**.

| Symbol | Addr | Role |
|---|---|---|
| `cfdl_io_in` | `0x15a20` | RX byte-stream state machine (defines the wire format) |
| `cfdl_io_msg_sen` | `0x15f64` | TX serialiser (`0x55`, header copy, checksum) |
| `cfdl_res_send` | `0x16480` | common sender — **stamps svc/dst/src into every message** |
| `cfdl_ro_heartbeat` | `0x16eb8` | replies to a received heartbeat |
| `cfdl_ro_send_heartbeat` | `0x167e0` | builds a heartbeat |
| `cfdl_ro_rolist_add` | `0x16a1c` | router peer table |
| `cfdl_info_get_data` | `0x12830` | device-describe request (msg `0x15`) |
| `cfdl_att_get_value` | `0xfc78` | *generic* attribute get (msg `0x05`, 4-byte path) |
| `cfdl_sattribute_get` / `_get_all` / `_set` | `0x1389c` / `0x13960` / `0x137d4` | BOYA attribute API (msg `0x1F`/`0x21`/`0x1E`) |
| `set_boya_mic_attr_value` etc. | `0x211b8`… | thin wrappers that pack the node handle |

Internal calls go through PLT stubs whose GOT slots carry `JUMP_SLOT` relocations
against the *exported* names, so PLT targets resolve cleanly to the symbol table.

---

## 4. The wire frame

All multi-byte integers are **little-endian** unless stated.

```
offset  size  field
   0      1   0x55                     sync
   1      1   0x10 | flags             high nibble = protocol version (1)
                                       low  nibble = fragment flags (0 normal, 3 fragment)
   2      2   payload_len              u16, max 0x480
   4      2   seq                      u16, incrementing
   6      1   src node                 host = 2, device = 1
   7      1   dst node                 host = 2, device = 1
   8      2   svc                      service id — 0x001D for everything (see §4.2)
  10      1   chid                     node address: channel id
  11      1   vid                      node address: logical vendor id
  12      2   pid                      node address: logical product id (u16)
  14      2   msg_id                   see §6
  16   len    payload
16+len    1   checksum
```

Total length = `payload_len + 17`.

### 4.1 Checksum

Plain 8-bit sum of **every preceding byte, including the `0x55` sync**:

```python
checksum = sum(frame[:-1]) & 0xFF
```

The RX state machine zeroes its accumulator when it sees `0x55`, then adds every
byte, and compares against the final byte before dispatching.

### 4.2 The `svc` field

`cfdl_res_send()` hard-codes `0x001D` into offset 8 for *every* outgoing message —
attribute reads, writes, device-describe and heartbeats alike. It also forces
`dst = 1` and fills `src` from a global set at init (the host is node **2**).

> **Correction.** An earlier revision of this document claimed the device only
> answers `svc = 0x1D` and that the iOS build's `0x1B` gets silence. That was
> wrong: the test that "proved" it also used `src = 1`, and *that* was the
> problem. Re-tested over the iAP transport with `src = 2`
> ([`scripts/svc_test.py`](./scripts/svc_test.py)): `svc` values `0x1B`, `0x1D`,
> `0x1E` and even `0x00` all get identical answers to `get nc`, while `src = 1`
> gets nothing whatever the `svc`. The iOS SDK build stamps `0x1B`, the Android
> build `0x1D` (it is a per-platform build constant, not transport-dependent);
> the device doesn't care. Replies always carry `0x1D`.

Frames *from* the device have been observed with `svc` `0x1D` and `0x1E`; treat any
of them as valid input.

### 4.3 Fragmentation / reassembly

A frame is **not** the same thing as a USB packet. Endpoints are 64 bytes; a full
attribute dump is ~127 bytes and simply continues into the next packet. Frames
shorter than a packet are zero-padded.

So the receive side must be a byte-stream reassembler, exactly like `cfdl_io_in`:

1. Scan for `0x55` followed by a byte whose high nibble is `0x1`.
2. Read 16 header bytes, take `payload_len` from offset 2.
3. Consume `payload_len` payload bytes plus 1 checksum byte.
4. Verify the checksum; resync on the next `0x55` if it fails.

Inter-frame zero padding is naturally skipped by the resync.

---

## 5. Node addressing

CFD-Link is a little routed bus. Two independent addressing layers exist:

**Link addresses** (`src`/`dst`, offsets 6–7): single bytes. The receiver is node
`1`, the host is node `2`. Send `src=2, dst=1`. Any `src` other than `1` works
(`3` verified); `src=1` is the device's own address and such frames are dropped.
The iOS SDK actually *starts* at `src=1`, collides with the device's router
heartbeat, and then moves itself to a random address; the Android SDK uses `2`.

The router **hands your own frames back** (same `src=2`, payload lightly
rewritten). Drop anything whose `src` isn't `1` or you will answer your own
heartbeats forever.

**Node handles** (`chid`, `vid`, `pid`, offsets 10–13): identify a *logical device*
on the bus. The SDK packs them into one 32-bit handle:

```c
handle = ((vid & 0xFF) << 8) | ((pid & 0xFFFF) << 16) | (chid & 0xFF);
```

`vid`/`pid` here are **CFD-Link logical ids and have nothing to do with USB
VID/PID**. `vid=0, pid=0, chid=0` is a broadcast.

### 5.1 Nodes on a mini 2

Observed on a real receiver (one TX paired, one absent):

| chid | vid | pid | Describe says | Role |
|---|---|---|---|---|
| 2 | 1 | 29 | (no reply) | router / loopback — `cfdl_ro_rolist_add` treats `vid=1,pid=0x1D,chid=<our addr>` as *self* |
| 2 | 2 | 30 | `no_attrs=True` | link endpoint, carries no settings |
| **1** | **2** | **29** | **`attr_by_id=True`** | **the node that holds every setting** |

> **Pitfall.** The node that heartbeats at you first is *not* the one with the
> settings. `(2,2,30)` advertises `isNoAtrr`, so querying it returns nothing at all.
> The settings node `(1,2,29)` never heartbeats — you only find it by sweeping
> device-describe across candidate addresses.

### 5.2 Known logical vid/pid values

From `DeviceManager` in APK 2.2.0 (`cFDLinkByID.vid/pid` → device class):

| vid | pid | Class |
|---|---|---|
| 1 | 73 | `WiTalkNeoFpDevice` |
| 1 | 74 | `WiTalkNeoPPDevice` |
| 1 | 78 | `BlinkM1Device` |
| 1 | 81 | `WiTalkFPDevice` |
| 1 | 83 | `GLinkRxDevice` |
| 2 | 16 | `BoYaMicDevice` |
| 2 | 20 | `OMic2Device` |
| 2 | 22 | `BoYaMic2Device` |
| 2 | 27 | `MM1AiDevice` |
| 2 | 28 | `BoYaAiRecDevice` |
| 2 | 29 | `BoYaMiniProDevice` |
| 2 | 31 | `BoYaMiniXDevice` |

Note that the mini 2's settings node reports **`vid=2, pid=29`** and the app maps
that to `BoYaMiniProDevice`, while the *attribute numbering* it uses is
`BoYaMic2AttrId`. `pid=30`, reported by the other node, has no class in 2.2.0 at
all. Don't over-trust these names — trust the capability bits from §7.

---

## 6. Message catalogue

`msg_id` sits at offset 14.

| msg_id | Name (SDK) | Direction | Payload |
|---|---|---|---|
| `0x00` | heartbeat | both | 13 bytes, see §8 |
| `0x05` | `cfdl_att_get_value` | → | 4-byte attribute *path* (generic attribute layer) |
| `0x09` | `cfdl_att_subscribe` | → | subscribe to attribute changes |
| `0x15` | `cfdl_info_get_data` | → | empty; reply describes the node (§7) |
| `0x1E` | `set_boya_mic_attr_value` | → | `[attrId, len, value…]` |
| `0x1F` | `get_boya_mic_attr_value` | → | `[attrId]` |
| `0x20` | `set_boya_mic_many_value` | → | raw blob |
| `0x21` | `get_boya_mic_many_value` | → | `[count, attrId…]`, `count = 0` ⇒ everything |

There are two parallel attribute systems in this SDK: the **generic** one
(`cfdl_att_*`, msg `0x05`/`0x09`, addressed by 4-byte *paths*) and the
**BOYA-specific** one (msg `0x1E`–`0x21`, addressed by flat 8-bit *attribute ids*).
The mini 2 uses the BOYA-specific one — its capability bits say so.

---

## 7. Device describe (`0x15`)

Request: `msg_id = 0x15`, empty payload, addressed to a node handle.

Reply payload:

```
[0]      currentIndex
[1]      totalLen
then repeating 5-byte records:
   [0]    des_id      (u8)
   [1:5]  des_value   (u32, BIG-endian)
```

Real capture, full frame, from node `(2,2,30)`:

```
55 11 1600 5500 02 02 1e00 02 01 1d00 1500   00 04 0a 00000000 0e 00000002 0f 00000002 09 00000004   64
                                             │  │  └ des10=0   └ des14=2   └ des15=2   └ des9=4
                                             │  └ totalLen 4
                                             └ currentIndex 0
```

The settings node `(1,2,29)` answers with `des9=0 des10=0 des14=0 des15=4 des16=1`.

Note the reply's node fields carry the *sender's* handle (here the router,
`chid=2 vid=1 pid=29`), not the handle you addressed.

`des_id` meanings, from `DeviceManager.updateCDLinkDeviceDes()`:

| des_id | Meaning |
|---|---|
| 1 | `audioIn` |
| 2 | `audioOut` |
| 3 | `notPower` |
| 4 | `deviceType` |
| 5 | character encoding |
| 6 | `deviceAttributeType` |
| 7 | `deviceUpdateRestartTimes` |
| 8 | `deviceSeriesType` |
| 9 | `isFirmwareCanUpgrade` (`== 1`) |
| 10 | `bmGroup` |
| 14 | `txType`; `deviceAttributeType = (value != 0)` |
| 15 | **capability bitmask** (below) |
| 16 | bit0 = `isCanRXGetTXAttr` |

### 7.1 The `des_id = 15` capability bitmask

| bit | Flag | Meaning |
|---|---|---|
| 0 | `isCanOldGetAttr` | legacy attribute API supported |
| 1 | `isNoAtrr` | **node has no attributes at all** |
| 2 | `isCanAttIDGetAttr` | attributes addressable by 8-bit id (msg `0x1E`–`0x21`) |

* `(1,2,29)` reports `4` → bit2 only → use msg `0x1F`/`0x21`. ✔
* `(2,2,30)` reports `2` → `isNoAtrr` → don't bother.

This bitmask is the reliable way to find the node worth talking to.

---

## 8. Session lifecycle — the heartbeat handshake

**The device will not answer anything until heartbeats are flowing.** This is the
single biggest gotcha.

The app never sends a request first: it claims the interface, registers a node,
starts reading, and waits. The receiver then emits heartbeats, and the SDK
(`cfdl_ro_heartbeat`) replies to each one. Only once that exchange is running does
the device respond to queries. In practice the host must *also* kick things off — a
broadcast heartbeat from the host reliably starts the conversation.

Heartbeat frame:

```
msg_id = 0x00, svc = 0x1D, src = 2, dst = 1
node handle = 0/0/0 (broadcast) or the peer's own handle when replying
payload = 13 bytes:
   [0]      role/type byte  (0x00 from host; device sends 0x00 or 0x04)
   [1:5]    u32 LE 0x01000400   (constant the app sends)
   [5]      0x09                (device sends 0x0A)
   [6:10]   u32 LE tick / uptime in ms
   [10:12]  u16 0
   [12]     0x24                (constant)
```

Real heartbeat from the receiver:

```
55 12 0d00 f50d 01 02 1d00 01 01 1d00 0000  00 a8 00 00 01 0a b0413600 0000 24  b3
│  │  │    │    │  │  │    │  │  │    │     └─ payload ─────────────────────┘  └checksum
│  │  │    │    │  │  │    │  │  │    └ msg_id 0
│  │  │    │    │  │  │    └──┴──┴──── chid=1 vid=1 pid=29
│  │  │    │    │  │  └─────────────── svc 0x1D
│  │  │    │    └──┴────────────────── src=1 (device) dst=2 (host)
│  │  │    └───────────────────────── seq 3573
│  │  └────────────────────────────── payload_len 13
│  └───────────────────────────────── 0x12 → version 1, flags 2
└──────────────────────────────────── sync
```

Recommended client loop: send a broadcast heartbeat every 500 ms, and reply to every
heartbeat received with one addressed back to the sender's node handle (swapping
`src`/`dst`). Keep this running for the whole session, including while waiting for
query responses.

---

## 9. Attributes

### 9.1 Read one — `0x1F`

Request payload: `[attrId]`

Reply payload: `[status, attrId, len, value…]`

Verified exchange — read noise cancellation from node `(chid=1, vid=2, pid=29)`:

```
→ 55 10 0100 0d00 02 01 1d00 01 02 1d00 1f00  2f  01
  │  │  │    │    │  │  │    │  │  │    │     │   └ checksum
  │  │  │    │    │  │  │    │  │  │    │     └───── payload: attrId 0x2F
  │  │  │    │    │  │  │    └──┴──┴────────────── chid=1 vid=2 pid=29
  │  │  │    │    └──┴────────────────────────── src=2 (host) dst=1 (device)
  │  │  │    └──────────────────────────────── seq 13
  │  │  └─────────────────────────────────── payload_len 1
  │  └──────────────────────────────────── 0x10 = version 1, no flags
  └───────────────────────────────────── sync

← 55 11 0400 0d00 01 02 1d00 02 01 1d00 1f00  00 2f 01 02  08
                                              │  │  │  └ value = 2
                                              │  │  └── len = 1
                                              │  └───── attrId = 0x2F
                                              └──────── status = 0 (OK)
```

### 9.2 Read everything — `0x21`

Request payload: `[0]` (count 0 = all).
Reply payload: `[status, (attrId, len, value…)*]` — ~110 bytes, spanning two USB
packets, so reassembly (§4.3) is mandatory.

### 9.3 Write — `0x1E`

Request payload: `[attrId, len, value…]`. Verified working: writing `47` (noise
cancellation) and `65` (output gain) both take effect immediately and read back
correctly.

### 9.4 Status codes

| status | Meaning |
|---|---|
| 0 | OK |
| 1 | attribute not available right now — e.g. a TX-side setting while that transmitter is offline |

### 9.5 Attributes on a BOYA mini 2

**This is the list that matters for this device — 25 attributes.** Every row here was
either returned by the receiver itself or is in BOYA's per-model metadata. Anything
*not* in this table is in §9.6 and does not exist on a mini 2.

Legend — **R/W**: `RW` settable, `RO` telemetry (writing is meaningless), `?`
unconfirmed. **Seen**: `dev` returned by the device's own `get_all`, `api` present in
BOYA's per-model list.

| id | hex | Name | R/W | Values | Seen |
|---:|---|---|:--:|---|---|
| 1 | 01 | `tx1_battery` | RO | 0..4 | dev+api |
| 2 | 02 | `tx1_charging` | RO | 0=Not Charging, 1=Charging, 2=Fully Charged | dev+api |
| 4 | 04 | `tx1_signal` | RO | 0..4 | dev+api |
| 7 | 07 | `tx1_wave` | ? | 0=Left Channel, 1=Right Channel | dev+api |
| 21 | 15 | `tx2_battery` | RO | 0..4 | dev+api |
| 22 | 16 | `tx2_charging` | RO | as id 2 | dev+api |
| 24 | 18 | `tx2_signal` | RO | 0..4 | dev+api |
| 27 | 1B | `tx2_wave` | ? | as id 7 | dev+api |
| **41** | 29 | **`scene_mode`** | **RW** ✔ | 0=Original, 1=Vocal Boost, 2=Low Cut 75Hz, 3=Low Cut 150Hz, 4=Custom EQ | dev+api |
| 42 | 2A | `audio_mode` | RO | 6-byte blob (api type: string) | dev+api |
| 44 | 2C | `tx_indicator_lights` | RW ✔ | 0..1 | dev+api |
| 45 | 2D | `tx_auto_poweroff` | RW | 0..1 | dev+api |
| 46 | 2E | `agc` | RW | 0..1 — TX-side, `status 1` when no TX connected | api |
| **47** | 2F | **`nc`** | **RW** ✔ | **0=Off, 1=Weak NC(−15dB), 2=Strong NC(−40dB)** | dev+api |
| 48 | 30 | `mute` | RW ✔ | 0..1 | dev+api |
| 61 | 3D | `rx_battery` | RO | 0..4 | dev+api |
| 62 | 3E | `rx_charging` | RO | as id 2 | dev+api |
| 63 | 3F | `tx1_online` | RO | **1=Online, 0=Offline** — BOYA's own label is inverted, see below | dev+api |
| 64 | 40 | `tx2_online` | RO | as id 63 | dev+api |
| **65** | 41 | **`rx_gain`** | **RW** ✔ | **1..6** | dev+api |
| 67 | 43 | `rx_auto_poweroff` | RW ✔ | 0..1 | dev+api |
| **68** | 44 | **`recording_mode`** | **RW** ✔ | 0=Mono, 1=Stereo, 2=Safety Channel | dev+api |
| 69 | 45 | `rx_speaker` | RW ⚠ | 0..1 — **restarts the receiver** | dev+api |
| 71 | 47 | `rx_reset` | ⚠ | **factory reset** | dev+api |
| 74 | 4A | `rx_camera_presets` | ? | 33-byte blob | dev |

✔ = read *and* write verified on hardware. ⚠ = has side effects; `boyactl.py`
requires `--force`.

**The settings you'd actually reach for:** `nc` (noise cancellation), `rx_gain`
(output level, 1..6), `scene_mode` (this is where low cut lives on a mini 2),
`recording_mode` (Mono / Stereo / Safety Channel), `mute`, `agc`.

**Gain range.** BOYA Central's `AddBOYAMic2FunModel:` sets −12..+12 for "RX Output
Gain", but that routine covers the whole family. The mini 2's own metadata says 1..6
and the device agrees: writing 7 or 0 leaves it sitting at 6. Trust 1..6.

**Online-status polarity — resolved: `1 = online`.** BOYA's api labels these
`0=Online, 1=Offline`; the device does the opposite. Verified by toggling the
transmitter (iAP transport, `getall`):

| | TX2 switched on | TX2 docked, +3 s | docked, +13 s |
|---|---|---|---|
| `tx2_online` | **1** | **0** | 0 |
| `tx2_battery` | 2 | 2 | 2 |
| `tx2_signal` | 4 | 3 | 3 |
| `tx2_charging` | 0 | 0 | 0 |

Two consequences. `tx*_online` is the **authoritative** connection flag and reacts
within ~3 s. **Battery and signal go stale, not zero**: 10 s after the TX was off the
receiver still reported the last-known battery and signal, and `charging` never
changed (the receiver can't see the dock). So never infer connection from
battery/signal — grey them out whenever `online = 0`.

**`rx_speaker`.** BOYA calls it "RX Speaker Mode" and the app warns *"Changing speaker
mode will restart the device."* Its actual effect is **unknown** — no enumeration or
description exists in any source. A plausible but untested hypothesis is that it
changes the USB audio descriptor the receiver presents (the mini 2 currently
enumerates as 2-channel input only), which would explain a restart.

### 9.6 Ids in the family table that are **not** on a mini 2

`com.jiayz.device.BoYaMic2AttrId` lists 58 ids because it serves the whole "Mic2"
family. These 33 are **not present on a mini 2** — the device returns `status 1` and
they are absent from its per-model metadata. Listed only so you can recognise them
when reading the APK:

| Ids | Names | Why they're absent |
|---|---|---|
| 15, 35 | `tx1_gain`, `tx2_gain` | no per-TX gain on a mini 2; the only gain is `rx_gain` (65) |
| 17–20, 37–40, 58, 60, 75 | `tx*_max_time`, `tx*_rec_time`, `tx*_format_flag`, `tx*_recording`, `tx_auto_rec`, `tx_rec_32bit`, `rx_single_rec` | the internal-recorder group — a mini 2 has no onboard recorder, so 32-bit-float recording does not exist here (and where it does exist it governs the TX's own recordings, never the USB stream) |
| 43 | `tx_low_cut` | folded into `scene_mode` (41) as Low Cut 75Hz / 150Hz |
| 76, 77, 81 | `rx_backlight_time`, `rx_screen_light`, `rx_language` | display settings; this receiver has no screen |
| 5, 6, 25, 26, 72, 73 | `tx*_sn`, `tx*_version`, `rx_sn`, `rx_version` | not exposed on this model |
| 3, 23, 8, 28, 59, 66, 70, 78, 79, 80, 82 | `tx*_mute`, `tx*_usb`, `tx_touch_lock`, `rx_output_type`, `rx_pair_en`, `rx_time_setting`, `rx_hp_input`, `rx_single_lock`, `rx_update_state` | — |

Conversely, id **48** (`mute`) is on the device and in the api list but **missing from
the java table** — so no single source is complete. The device is the final authority.

### 9.7 Determining this for a different model

1. **Ask the device.** `get_all` (msg `0x21`, count 0) returns exactly what it
   implements. Individual reads of anything else give `status 1`. Ground truth — but a
   *lower* bound, since TX-side attributes drop out when no transmitter is on.
2. **Ask BOYA's API** (§11) with that product's name, e.g.
   `{"productName":"BOYA mini 2 RX"}` and `"… TX"`. Each entry's `functionNumber` *is*
   the attribute id, and you get names plus value enumerations. Note `readOnly` is `0`
   on every row and `attributeType` describes the UI widget, not writability — neither
   tells you whether an attribute is settable.
3. **The java `*AttrId` class** for the family — names only, and it over-lists.

Intersect (1) and (2); use (3) just to name leftovers.

### 9.8 A real device dump

`./boyactl.py getall` (iAP transport, no sudo — byte-identical to the earlier
`sudo` run over interface 0), one TX paired:

```
  1  0x01  tx1_battery            0
  2  0x02  tx1_charging           0  (Not Charging)
  4  0x04  tx1_signal             0
  7  0x07  tx1_wave               0  (Left Channel)
 21  0x15  tx2_battery            3
 22  0x16  tx2_charging           0  (Not Charging)
 24  0x18  tx2_signal             4
 27  0x1B  tx2_wave               1  (Right Channel)
 41  0x29  scene_mode             0  (Original)
 42  0x2A  audio_mode             000000000000
 44  0x2C  tx_indicator_lights    1
 45  0x2D  tx_auto_poweroff       1
 47  0x2F  nc                     2  (Strong NC(-40dB))
 48  0x30  mute                   0
 61  0x3D  rx_battery             4
 62  0x3E  rx_charging            2  (Fully Charged)
 63  0x3F  tx1_online             0  (Offline)
 64  0x40  tx2_online             1  (Online)
 65  0x41  rx_gain                4
 67  0x43  rx_auto_poweroff       1
 68  0x44  recording_mode         0  (Mono)
 69  0x45  rx_speaker             1
 71  0x47  rx_reset               0
 74  0x4A  rx_camera_presets      000000…  (33 bytes)
```

That is 24 of the 25 attributes in §9.5 — `agc` (46) is missing because no
transmitter was connected. `get_all` only returns what is currently meaningful.

---

## 10. Talking to it from each OS

### Android (what the app does)

`com.jiayz.device.CFDLinkHidManager`:

```java
mInterface = usbDevice.getInterface(0);
usbEpIn  = mInterface.getEndpoint(0);   // 0x82
usbEpOut = mInterface.getEndpoint(1);   // 0x02
mDeviceConnection.claimInterface(mInterface, true);
...
mDeviceConnection.bulkTransfer(usbEpOut, frame, frame.length, 100);
```

Raw frame, no report ID, no wrapper. (A `+1` length prefix of `0x01` exists but only
for "BlinkM1" devices, USB pid `65535`/`8` — not the mini 2.)

### Linux

Detach `usbhid` from interface 0 and claim it; everything else stays bound. This is
the cleanest platform for this device. *(Untested here — no Linux box available —
but it follows directly from the Android path.)*

### macOS — use the iAP interface

What macOS binds to the receiver (`ioreg -r -n "BOYA mini 2" -l`):

```
IOUSBHostDevice "BOYA mini 2"          Authenticated = Yes, iAPAuthenticator = accessoryd
├── IOUSBHostInterface@0  → AppleUserUSBHostHIDDevice (DriverKit) → IOHIDInterface → AppleUserHIDEventDriver
├── iAP Interface@1       → (no driver) only a dormant AppleUSBHostInterfaceUserClient from accessoryd
├── IOUSBHostInterface@2  → AppleUSBAudioControlNub + usbaudiod
└── IOUSBHostInterface@3  → usbaudiod
```

Interface 0 is owned by a DriverKit HID driver, and the four ways of getting at it
range from dead to painful:

1. **hidapi / IOHIDDevice** — dead. Writes are accepted but the device never
   answers, and even if it did, IOHIDFamily only delivers input reports whose first
   byte is a report ID from the descriptor (it creates one "report handler element"
   per declared ID); a raw `0x55` frame from the device is dropped in the kernel.
2. **`USBInterfaceOpenSeize`** via IOUSBLib — refused with `kIOReturnExclusiveAccess
   (0xe00002c5)` even as root on macOS 26, because a DriverKit driver holds the
   interface. Kept in [`boyabridge.c`](./boyabridge.c) for reference.
3. **libusb + root** — works. `libusb_detach_kernel_driver()` on macOS *captures the
   whole device* (`USBDeviceReEnumerate` with `kUSBReEnumerateCaptureDeviceMask`), so
   the receiver's **USB audio interfaces detach too** while the tool runs, and the
   capture re-enumerates the device (your handle goes stale — re-find it). Fine for
   a short CLI call, wrong for anything long-running. `boyactl.py --transport libusb`.
4. **The iAP interface** ✔ — the right answer. Interface 1 is `bInterfaceClass 0xFF`
   / `0xF0` ("iAP Interface", bulk `0x01` OUT / `0x81` IN) and **nothing on macOS
   drives it**. `accessoryd` (Apple's CoreAccessories daemon) opens it once at plug-in
   to run MFi authentication — hence `Authenticated = Yes` on the device — and then
   sits on a user client without holding the pipe open. So a plain
   `libusb_claim_interface(1)` succeeds as a normal user, nothing is captured, the
   audio stays bound, and the device doesn't re-enumerate. On that pipe the receiver
   speaks **iAP2**, and CFD frames ride inside an External Accessory session — the
   iPhone's path, described in §13. `boyactl.py` does this by default; the iAP2 host
   side is [`scripts/iap2.py`](./scripts/iap2.py).

   Notes: pyusb's `is_kernel_driver_active(1)` reports `True` (libusb sees the
   `accessoryd` client) — ignore it, don't call `detach_kernel_driver`, just claim.
   A *botched* iAP2 link attempt (e.g. sending your own SYN instead of answering the
   accessory's) makes the receiver **re-enumerate itself** a moment later; a properly
   closed session does not.

   What about `ExternalAccessory.framework`? It ships on macOS and `EASession` is
   declared for macOS 10.13+, but in practice it is the iOS client library:
   `EAAccessoryManager` → `IAPAppRegisterClient` (private `IAP.framework`) connects to
   `com.apple.iap2d.xpc` / `com.apple.iapd.xpc`, and those daemons don't exist on
   macOS (`accessoryd` only vends `com.apple.accessories.externalaccessory-server`,
   which the framework never uses). Result: `registerWasSuccessful 0`,
   `IAP2DHasLaunched 0`, zero accessories. Probe in
   [`scripts/eaprobe.swift`](./scripts/eaprobe.swift). Speak iAP2 yourself instead.

### 10.1 How the interface-1 lead was resolved

An earlier revision recorded that `libusb_claim_interface(1)` works unprivileged and
that a CFD heartbeat frame could be seen on `0x81` behind an undecoded prefix
(`e0 14 00 00 00 24 51 | 55 10 0d00 …`). That prefix was the tail of an **iAP2 link
packet** (`… | u16 EA-session id | CFD frame`, see §13.3) — stray traffic from the
receiver's link with `accessoryd` at plug-in time. Producing the wrapper turned out
to be a small iAP2 host implementation (§13): echo the accessory's detect, accept
its SYN, identify, open the EA session. No MFi authentication is needed in this
direction. Co-existence with `accessoryd` has been fine over many open/close cycles.

---

## 11. The cloud API

The apps fetch per-product UI/attribute metadata from `https://app.release.jiayz.com`.
All endpoints are **POST with `Content-Type: application/json`**; GET returns
`{"msg":"Request method 'GET' not supported","code":500}`.

```sh
curl -s -X POST https://app.release.jiayz.com/api/product/getProductFunctionList \
     -H 'Content-Type: application/json' \
     -d '{"productPid":"0x3B","productVid":"0x2F05","productName":"BOYA mini 2"}'
```

Returns `data.commonFunctionList` — 96 attribute descriptors (Chinese/English/Russian
triplicates) with `attributeName`, `attributeType`, `attributeRange` and a Chinese
`functionDes` explaining each. Useful for value enumerations, e.g.:

* `Low Cut` → `{"Off","80Hz","120Hz","160Hz"}`
* `Backlight Mode` → `{"on","10s","30s","60s"}`
* `Output Mode` → `{"Mono","Stereo"}`
* `Sta` → `{"connecting","disconnect","connected","pairing"}`

Other endpoints seen in the binaries: `/api/product/getProductMsg`,
`getProductStyleList`, `getProductStyleBySN`, `getProductKeysetList`,
`getFunctionAndStyle`, `getProductFirmware`, `getNewVersion`,
`/api/product/upgrade/record`, `/appdata/checkAppUpgrade`,
`/appdata/getBulletinBoard`, `/api/boya/save/connect`.

Firmware metadata also lives at
`https://www.saramonic.com/software/firmware/update/test/device_update_debug.json`.

---

## 12. Bluetooth

The iOS app declares `NSBluetoothAlwaysUsageDescription`, `bluetooth-central` and a
`BluetoothTool` class, and the binary contains these custom GATT UUIDs:

```
D8528400-66F0-40FF-8F3D-BC7A9853E04A   (service)
D8528401-66F0-40FF-8F3D-BC7A9853E04A   (characteristic)
D8528402-66F0-40FF-8F3D-BC7A9853E04A   (characteristic)
F081B1A1-DAE2-4CFE-9860-FF37D3D28B21
```

The SDK carries a parallel `ble_port` alongside `hid_mfi_port`
(`setBleConnectType` vs `setHidMFiConnectType`), and the Android app has a whole
separate BLE connection path (`BLEDeviceConnectActivity`, `BleScanUtils`). So
CFD-Link can evidently ride over BLE for products that support it.

**None of this applies to the mini 2, and none of it was used here.** Concretely:

* The receiver's USB descriptors expose HID + iAP + audio and nothing else; `ioreg`
  shows zero Bluetooth services under the device.
* It never appears in macOS Bluetooth — it is not a Bluetooth peripheral.
* The BLE UUIDs above appear only in the **iOS** binary, which is one app covering
  BOYA's whole product line; they are absent from the Android app entirely.
* The mini 2 goes through `CFDLinkHidManager` (USB), not the BLE path.

The TX↔RX radio link is BOYA's own **2.4 GHz** protocol, which is not Bluetooth — it
just shares the ISM band. Everything in this document was done over USB.

---

## 13. iOS / MFi path — iAP2 over the iAP interface

The iOS app uses the External Accessory framework, protocol string
**`BOYA.DeviceLink.com`** (`UISupportedExternalAccessoryProtocols`), over the
receiver's iAP interface. Its `EADSession` class is the transport and the same CFD
frames ride on top. On macOS we do the iPhone's job ourselves; everything below
is verified against the receiver with [`scripts/iap2.py`](./scripts/iap2.py).

### 13.1 iAP2 link layer

Roles matter: **the accessory initiates**. If you send your own SYN the receiver
ignores it and re-enumerates shortly after.

```
accessory → host   FF 55 02 00 EE 10                      "iAP2 detect"
host → accessory   FF 55 02 00 EE 10                      echo it (that's the reply)
accessory → host   SYN  (link parameters + session list)
host → accessory   SYN|ACK, ack = accessory seq, payload = the parameters you accept
                   (echoing the accessory's verbatim works)
accessory → host   ACK
```

Link packet:

```
offset size
   0     2   FF 5A
   2     2   total packet length, big-endian (header + payload + payload checksum)
   4     1   control: SYN 0x80  ACK 0x40  EAK 0x20  RST 0x10  SLP 0x08
   5     1   seq
   6     1   ack
   7     1   session id
   8     1   header checksum: sum of bytes 0..8 == 0 (mod 256)
   9    n    payload
  9+n    1   payload checksum: sum of payload bytes == 0 (mod 256)   [absent if n == 0]
```

The receiver's SYN, as captured:

```
ff5a 001a 80 01 10 00 fc | 01 05 0400 1388 00ff 1e 03 | 01 00 01 | 02 02 01 | 34
                           │  │  │    │    │    │  └ max cumulative acks 3
                           │  │  │    │    │    └ max retransmissions 30
                           │  │  │    │    └ cumulative-ack timeout 255 ms
                           │  │  │    └ retransmission timeout 5000 ms
                           │  │  └ max packet length 1024
                           │  └ max outstanding packets 5
                           └ link version 1
                           sessions: id 1 = control (type 0) v1, id 2 = EA (type 2) v1
```

Every data packet (payload present) must be ACKed: send a bare packet with
`ctrl = ACK`, `ack = its seq`, `seq = your current seq`. Your own data packets
consume a new `seq` each and carry `ACK` plus your current `ack`. Duplicates
(retransmissions) arrive with the same `seq` — ignore them after ACKing. Packets
longer than 64 bytes simply continue across bulk packets; parse a byte stream.

### 13.2 Control session (session id 1)

Message: `40 40 | u16 BE total length | u16 BE message id | parameters*`, each
parameter `u16 BE length (incl. this 4-byte header) | u16 BE id | data`.

Sequence that gets to an EA session:

| dir | id | message | notes |
|---|---|---|---|
| → | `0x1D00` | `StartIdentification` | no params |
| ← | `0x1D01` | `IdentificationInformation` | see below |
| → | `0x1D02` | `IdentificationAccepted` | |
| ← | `0xAE00` | `PowerSourceUpdate` | ignore |
| ← | `0xAE03` | `StopPowerUpdates` | ignore |
| → | `0xEA00` | `StartExternalAccessoryProtocolSession` | param 0 = protocol id (u8), param 1 = session id (u16) |
| ← | `0xEA03` | `StatusExternalAccessoryProtocolSession` | param 0 = session id, param 1 = status (`0` open, `1` closed) |
| → | `0xEA01` | `StopExternalAccessoryProtocolSession` | param 0 = session id; do this on exit |

MFi authentication (`0xAA00`…`0xAA05`) is the *accessory* proving itself to the
*host*; as the host you can simply not ask. The receiver doesn't insist.

`IdentificationInformation` from the receiver:

| param | value |
|---|---|
| 0 Name | `Microphone` |
| 1 ModelIdentifier | `BOYA mini 2` |
| 2 Manufacturer | `Shenzhen jiayz photo industrial ltd` |
| 3 SerialNumber | `CFD7387E79` |
| 4 / 5 Firmware / Hardware | `1.1.0` / `1.1.0` |
| 6 MessagesSentByAccessory | `PowerSourceUpdate`, `PowerUpdate`, `StopPowerUpdates` |
| 7 MessagesReceivedFromDevice | `StartPowerUpdates`, `StartExternalAccessoryProtocolSession`, `StopExternalAccessoryProtocolSession` |
| 8 / 9 | power-providing `2`, max current `100 mA` |
| **10 SupportedExternalAccessoryProtocol** | **id `177`, name `BOYA.DeviceLink.com`, match action `0`** |
| 12 / 13 | language `en` |
| 16 USBHostTransportComponent | id `1`, name `iAP2H`, iAP2-supported |
| 34 (unknown) | `25964b2d38e94eee` |

### 13.3 EA session (session id 2) — where CFD-Link lives

EA data packet payload = `u16 BE EA-session id` (the one you chose in
`StartExternalAccessoryProtocolSession`, e.g. `1`) followed by **raw CFD bytes**.
There is no wrapper, no length prefix, no different sync byte — the iOS app's
`writeCallBack` hands `cfdl_io_msg_sen()`'s output straight to `EASession`
(chunked at 500 bytes with 5 ms gaps for big transfers), and its read side feeds
whatever arrives into `cfdl_io_in()`. So the CFD layer is identical to USB:
heartbeat first, reply to heartbeats, then talk to node `(1,2,29)`. A full
exchange, host `get nc`:

```
→ ff5a 001d 40 6b 06 02 ..  0001  55 10 01 00 xx xx 02 01 1d 00 01 02 1d 00 1f 00  2f  cc  pc
                              │     └────────── CFD frame, exactly as on USB ──────────┘
                              └ EA session id 1
← ff5a 0020 40 07 6b 02 ..  0001  55 11 04 00 xx xx 01 02 1d 00 02 01 1d 00 1f 00  00 2f 01 02  cc  pc
```

Two iOS-app quirks, for completeness (neither is needed): its heartbeat constant is
`0x01000480` (Android/`boyactl.py` send `0x01000400`; both work), and for the first
10 s after connect it refuses to write any frame whose hex contains
`1e 00 47 01 01` — a guard against an accidental factory reset (`set rx_reset 1`).

### 13.4 The `55 40 …` frames — not for this device

`-[CFDLinkTool getMfiDeviceInfo:len:port:]` parses a second frame family
`55 40 <len> <cmd> <payload>` (cmd `0x10` len `0x0A` = system info, `0x15` len 4 =
version, `0x16` = serial, `0x14` len 2 = TX state; host templates
`55 40 01 15`, `55 40 01 10`, `55 40 01 16`, `55 40 02 14`, `55 40 02 13`,
`55 40 02 11`). The app only routes data there when the connected node is a
**BOYA-Link** (`vid=2, pid=0x12`); mini 2 data goes straight to `cfdl_io_in`.
Ignore it.

---

## 14. Pitfalls, in the order they bit me

1. **`src=2, dst=1`.** Sending `src=1` gets silence — and that, not the `svc`
   value, was the real cause of the "0x1B vs 0x1D" confusion. `svc` is ignored.
2. **No heartbeats, no answers.** The device is mute until the heartbeat exchange is
   running, and it needs the host to start it.
3. **The settings node isn't the one that heartbeats.** Sweep device-describe and
   look for capability bit 2 (`isCanAttIDGetAttr`).
4. **The router hands your own frames back.** Drop frames whose `src` isn't `1`, or
   you answer your own heartbeats in a loop.
5. **On macOS, use interface 1 (iAP), not interface 0.** HID APIs cannot work
   (kernel drops undeclared report IDs on input), seize is refused, and libusb
   capture needs root and kills the audio. The iAP interface needs none of that.
6. **iAP2: the accessory initiates.** Echo its detect, answer its SYN with SYN|ACK.
   Sending your own SYN gets nothing and the receiver re-enumerates.
7. **`ExternalAccessory.framework` on macOS is a mirage** — it wants `iap2d`, which
   only exists on iOS.
8. **libusb capture invalidates your device handle.** Re-find after detaching.
9. **A USB packet is not a frame.** Reassemble by length, or a full `get_all` looks
   truncated at 14 attributes.
10. **The official Android APK link is stale (1.1.2).** Use `checkAppUpgrade`.
11. **The macOS desktop app doesn't support this product** — don't use it as a model.
12. **iOS attribute-id guesses were wrong** for TX gain; use the Java `*AttrId`
    classes.

---

## 15. Tooling in this repo

| File | What |
|---|---|
| `boyactl.py` | Working CLI: `attrs`, `peers`, `getall`, `get`, `set`, `monitor`. Transports: `iap` (default, no sudo), `libusb` (capture, sudo), `bridge` (dead) |
| `scripts/iap2.py` | Minimal iAP2 host: link layer, identification, EA session. Used by `boyactl.py`; run it directly to identify the accessory |
| `scripts/iap2probe.py` | The exploratory iAP2 probe that first got through (verbose, standalone) |
| `scripts/svc_test.py` | The `svc`/`src` experiment behind §4.2 |
| `scripts/eaprobe.swift`, `scripts/eaprobe-Info.plist` | macOS `ExternalAccessory.framework` probe — shows why it can't work here. Build: `swiftc -o eaprobe eaprobe.swift -framework ExternalAccessory -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker eaprobe-Info.plist` |
| `scripts/lldb_dumpstr.py` | lldb script: dump `__cstring`/ObjC names of `IAP`/`ExternalAccessory` from a live process (they live in the dyld shared cache) |
| `scripts/methods.py`, `scripts/ann.py`, `scripts/disas.py` | iOS-binary RE helpers: resolve ObjC method lists, annotate `otool -tV` output, print one method |
| `boyabridge.c` | IOUSBLib seize experiment — non-functional on macOS 26, kept for reference |
| `BOYA.app/` | iOS app bundle (v2.3.3) |
| `BOYA_Central_android.apk`, `apk/`, `apk-src/` | Android 1.1.2 + `libcfdlink.so` (symbols) |
| `BOYA_Central_2.2.0.apk`, `apk2/`, `apk2-src/` | Android 2.2.0 — has `BoYaMic2AttrId` |

Usage (no sudo):

```sh
.venv/bin/python boyactl.py peers        # show the bus and capability bits
.venv/bin/python boyactl.py getall       # dump every attribute
.venv/bin/python boyactl.py get nc       # noise cancellation
.venv/bin/python boyactl.py set nc 1     # 0 off / 1 / 2
.venv/bin/python boyactl.py set rx_gain 6
.venv/bin/python scripts/iap2.py         # iAP2 identification only
sudo .venv/bin/python boyactl.py --transport libusb getall   # old route, interface 0
```

---

## 16. Open questions

* What `rx_speaker` (69) actually does. It restarts the receiver, so it was not
  tried; diffing the USB descriptors either side of a toggle would answer it.
* Whether `tx1_wave` / `tx2_wave` (7, 27) are settable — they assign a transmitter to
  the Left or Right channel, but BOYA's own name for them is "Sound wave *display*".
* ~~The polarity of `tx1_online` / `tx2_online`~~ — **resolved**, `1 = online`; see §9.5.
* Payload meaning of `audio_mode` (42, 6 bytes) and `rx_camera_presets` (74, 33 bytes).
* The generic attribute layer (msg `0x05`, 4-byte paths) is unused by this device;
  the path encoding was not decoded.
* ~~The iAP-interface transport~~ — **resolved**, see §10 (route 4) and §13. It is
  now the default transport.
* Two settable attributes are still unwritten: `tx_auto_poweroff` (45) and `agc`
  (46, needs a connected transmitter). Every other `RW` row in §9.5 has been written
  and read back.
* The BLE transport (§12).
* Firmware update path (`HidUpgradeApi`, `dfu_*` symbols, `create_bootloader_msg_packet`)
  — deliberately left alone.
* `IdentificationInformation` parameter **34** (`25964b2d38e94eee`) has no name in
  the public iAP2 parameter list.
* Whether `accessoryd` ever wants the iAP interface back after plug-in. It hasn't
  complained; sessions have been opened and closed repeatedly with the device
  staying enumerated and the audio untouched.
