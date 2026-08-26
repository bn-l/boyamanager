#!/usr/bin/env python3
"""
boyactl - read and change BOYA mini 2 settings from the command line,
without the BOYA Central app.

    ./boyactl.py getall
    ./boyactl.py get nc
    ./boyactl.py set nc 1
    ./boyactl.py attrs
    ./boyactl.py monitor

How it works
------------
The receiver (USB 0x2F05:0x003B) speaks BOYA's "CFD-Link" protocol.  There are
two ways onto it:

* iap (default) - the receiver's MFi "iAP Interface" (USB interface 1, bulk
  0x01 OUT / 0x81 IN).  We play the iPhone: bring up an iAP2 link, identify the
  accessory, open an External Accessory session for "BOYA.DeviceLink.com" and
  push CFD frames through it - exactly what BOYA's iOS app does.  On macOS no
  driver binds that interface, so this needs no sudo and leaves the receiver's
  USB audio untouched.  See scripts/iap2.py.
* libusb - the vendor/HID interface (interface 0, interrupt 0x02 OUT / 0x82 IN)
  with raw frames, the way the Android app does it.  On macOS this requires
  capturing the whole device (sudo) and knocks the audio interfaces off while
  the tool runs.  Kept for Linux and as a fallback.

Wire frame (little-endian):
    [0]      0x55                sync
    [1]      0x10 | flags        protocol version | fragment flags
    [2:4]    u16 payload_len
    [4:6]    u16 seq
    [6]      src node            (host = 2)
    [7]      dst node            (device = 1)
    [8:10]   u16 0x001D          service id (cfdl_res_send hardcodes this)
    [10]     chid
    [11]     vid
    [12:14]  u16 pid
    [14:16]  u16 msg_id
    [16:]    payload
    [-1]     checksum = sum(frame[:-1]) & 0xFF

The receiver only answers while heartbeats are flowing, and the settings live
on a sub-node of the link (chid=1 vid=2 pid=29), not on the node that
heartbeats first.  Session below handles both.
"""
import argparse, os, struct, sys, time

USB_VID, USB_PID = 0x2F05, 0x003B
EP_OUT, EP_IN = 0x02, 0x82
IAP_INTERFACE = 1
EA_PROTOCOL = "BOYA.DeviceLink.com"

MSG_HEARTBEAT  = 0x00
MSG_DEVICE_DES = 0x15   # cfdl_info_get_data  - ask a node to describe itself
MSG_SET_ATTR   = 0x1E   # payload [attrId, len, *value]
MSG_GET_ATTR   = 0x1F   # payload [attrId]
MSG_GET_MANY   = 0x21   # payload [count, *attrIds]; count 0 => everything

SVC = 0x1D
HEARTBEAT_SVCS = (0x1D, 0x1E)

HOST_NODE, DEVICE_NODE = 2, 1
DEFAULT_TARGET = (1, 2, 29)          # chid, vid, pid - the node with attributes

# Attribute ids.  Names/ranges/labels marked (api) come from BOYA's own product
# metadata -- POST /api/product/getProductFunctionList with
# {"productName":"BOYA mini 2 RX"} -- and are authoritative for this model.
# The rest come from com.jiayz.device.BoYaMic2AttrId in the APK, which covers the
# whole "Mic2" family, so some of those ids do not exist on a mini 2.
# Entry: id -> (name, (lo, hi) | None, {value: label} | None)
CHARGING = {0: "Not Charging", 1: "Charging", 2: "Fully Charged"}
ONLINE   = {0: "Offline", 1: "Online"}          # BOYA's api says the opposite; verified by toggling a TX (manual §9.5)
LR       = {0: "Left Channel", 1: "Right Channel"}

ATTRS = {
    1:  ("tx1_battery",        (0, 4), None),           # (api)
    2:  ("tx1_charging",       (0, 2), CHARGING),       # (api)
    3:  ("tx1_mute",           (0, 1), None),
    4:  ("tx1_signal",         (0, 4), None),           # (api)
    5:  ("tx1_sn",             None,   None),
    6:  ("tx1_version",        None,   None),
    7:  ("tx1_wave",           (0, 1), LR),             # (api)
    8:  ("tx1_usb",            None,   None),
    15: ("tx1_gain",           None,   None),
    17: ("tx1_max_time",       None,   None),
    18: ("tx1_rec_time",       None,   None),
    19: ("tx1_format_flag",    None,   None),
    20: ("tx1_recording",      None,   None),
    21: ("tx2_battery",        (0, 4), None),           # (api)
    22: ("tx2_charging",       (0, 2), CHARGING),       # (api)
    23: ("tx2_mute",           (0, 1), None),
    24: ("tx2_signal",         (0, 4), None),           # (api)
    25: ("tx2_sn",             None,   None),
    26: ("tx2_version",        None,   None),
    27: ("tx2_wave",           (0, 1), LR),             # (api)
    28: ("tx2_usb",            None,   None),
    35: ("tx2_gain",           None,   None),
    37: ("tx2_max_time",       None,   None),
    38: ("tx2_rec_time",       None,   None),
    39: ("tx2_format_flag",    None,   None),
    40: ("tx2_recording",      None,   None),
    41: ("scene_mode",         (0, 4),                  # (api)
         {0: "Original", 1: "Vocal Boost", 2: "Low Cut 75Hz",
          3: "Low Cut 150Hz", 4: "Custom EQ"}),
    42: ("audio_mode",         None,   None),           # (api) "RX Audio Mode"
    43: ("tx_low_cut",         None,   None),
    44: ("tx_indicator_lights", (0, 1), None),          # (api)
    45: ("tx_auto_poweroff",   None,   None),           # (api)
    46: ("agc",                (0, 1), None),           # (api)
    47: ("nc",                 (0, 2),                  # (api)
         {0: "Off", 1: "Weak NC(-15dB)", 2: "Strong NC(-40dB)"}),
    48: ("mute",               (0, 1), None),           # (api) "RX Mute Status"
    58: ("tx_auto_rec",        (0, 1), None),
    59: ("tx_touch_lock",      (0, 1), None),
    60: ("tx_rec_32bit",       (0, 1), None),
    61: ("rx_battery",         (0, 4), None),           # (api)
    62: ("rx_charging",        (0, 2), CHARGING),       # (api)
    63: ("tx1_online",         (0, 1), ONLINE),         # (api)
    64: ("tx2_online",         (0, 1), ONLINE),         # (api)
    65: ("rx_gain",            (1, 6), None),           # (api) verified by probing
    66: ("rx_output_type",     None,   None),
    67: ("rx_auto_poweroff",   None,   None),           # (api)
    68: ("recording_mode",     (0, 2),                  # (api)
         {0: "Mono", 1: "Stereo", 2: "Safety Channel"}),
    69: ("rx_speaker",         (0, 1), None),           # (api) restarts the device
    70: ("rx_pair_en",         (0, 1), None),
    71: ("rx_reset",           None,   None),           # (api) factory reset
    72: ("rx_sn",              None,   None),
    73: ("rx_version",         None,   None),
    74: ("rx_camera_presets",  None,   None),
    75: ("rx_single_rec",      None,   None),
    76: ("rx_backlight_time",  None,   None),
    77: ("rx_screen_light",    None,   None),
    78: ("rx_time_setting",    None,   None),
    79: ("rx_hp_input",        None,   None),
    80: ("rx_single_lock",     (0, 1), None),
    81: ("rx_language",        None,   None),
    82: ("rx_update_state",    None,   None),
}
BY_NAME = {v[0]: k for k, v in ATTRS.items()}

# Changing these has consequences beyond a settings tweak.
RISKY = {69: "changing speaker mode restarts the receiver",
         71: "factory reset", 70: "starts re-pairing"}


def attr_id(token):
    """Accept either a name ('nc') or a number ('47' / '0x2F')."""
    return BY_NAME[token] if token in BY_NAME else int(token, 0)


def attr_name(aid):
    return ATTRS.get(aid, ("?", None, None))[0]


def build(msg_id, payload=b"", chid=0, vid=0, pid=0, seq=1,
          src=HOST_NODE, dst=DEVICE_NODE, port=SVC, flags=0):
    body = (bytes([0x55, 0x10 | flags])
            + struct.pack("<HH", len(payload), seq)
            + bytes([src, dst])
            + struct.pack("<H", port)
            + bytes([chid, vid])
            + struct.pack("<HH", pid, msg_id)
            + payload)
    return body + bytes([sum(body) & 0xFF])


def parse(buf):
    buf = bytes(buf)
    if len(buf) < 17 or buf[0] != 0x55 or (buf[1] & 0xF0) != 0x10:
        return None
    ln, seq = struct.unpack_from("<HH", buf, 2)
    pid, msg_id = struct.unpack_from("<HH", buf, 12)
    return dict(flags=buf[1] & 0xF, len=ln, seq=seq, src=buf[6], dst=buf[7],
                port=struct.unpack_from("<H", buf, 8)[0],
                chid=buf[10], vid=buf[11], pid=pid, msg_id=msg_id,
                payload=buf[16:16 + ln])


def decode_attrs(payload):
    """[status, (attrId, len, value...)*] -> [(attrId, value bytes), ...]"""
    out, i = [], 1
    while i + 1 < len(payload):
        aid, n = payload[i], payload[i + 1]
        val = payload[i + 2:i + 2 + n]
        if n == 0 or len(val) < n:
            break
        out.append((aid, bytes(val)))
        i += 2 + n
    return out


def fmt_value(aid, val):
    if len(val) != 1:
        return val.hex()
    nm, rng, labels = ATTRS.get(aid, ("?", None, None))
    n = val[0]
    if rng and rng[0] < 0 and n > 127:          # signed range -> signed byte
        n -= 256
    return f"{n}  ({labels[n]})" if labels and n in labels else str(n)


class Link:
    """Raw USB access to the receiver's vendor interface."""

    def __init__(self, verbose=False):
        import usb.core, usb.util
        self.usb, self.util = usb.core, usb.util
        self.verbose = verbose

        dev = usb.core.find(idVendor=USB_VID, idProduct=USB_PID)
        if dev is None:
            raise SystemExit("BOYA mini 2 receiver not found on USB")

        # libusb on macOS takes the interface by *capturing* the whole device,
        # which re-enumerates it, so the first handle goes stale - re-find it.
        captured = False
        try:
            if dev.is_kernel_driver_active(0):
                dev.detach_kernel_driver(0)
                captured = True
        except Exception as e:
            raise SystemExit(
                f"could not take interface 0 from the kernel HID driver: {e}\n"
                "On macOS this needs root - rerun with sudo.")

        if captured:
            dev = None
            deadline = time.time() + 10
            while time.time() < deadline:
                dev = usb.core.find(idVendor=USB_VID, idProduct=USB_PID)
                if dev is not None:
                    try:
                        dev.get_active_configuration()
                        break
                    except Exception:
                        dev = None
                time.sleep(0.02)
            if dev is None:
                raise SystemExit("device did not come back after capture")

        self.dev = dev
        usb.util.claim_interface(dev, 0)

    def close(self):
        try:
            self.util.release_interface(self.dev, 0)
            self.dev.attach_kernel_driver(0)
        except Exception:
            pass

    def send(self, frame):
        if self.verbose:
            print("TX", frame.hex(), file=sys.stderr)
        return self.dev.write(EP_OUT, frame, timeout=300)

    def recv(self, seconds):
        out, t = [], time.time()
        while time.time() - t < seconds:
            try:
                data = bytes(self.dev.read(EP_IN, 64, timeout=200))
            except Exception as e:
                if "timeout" in str(e).lower() or getattr(e, "errno", None) == 60:
                    continue
                break
            if self.verbose:
                print("RX", data.hex(), file=sys.stderr)
            out.append(data)
        return out


class IapLink:
    """CFD-Link inside an iAP2 External Accessory session on USB interface 1.

    This is the iPhone's route into the receiver.  No kernel driver claims the
    iAP interface on macOS, so it opens as a normal user without capturing the
    device, and the receiver's USB-audio interfaces stay bound.
    """

    def __init__(self, verbose=False):
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))
        import iap2
        self.iap2 = iap2
        self.verbose = verbose
        try:
            self.dev = iap2.claim(USB_VID, USB_PID, IAP_INTERFACE)
        except iap2.Iap2Error as e:
            raise SystemExit(str(e))
        self.host = iap2.Iap2Host(self.dev, verbose=verbose)
        try:
            self.host.open(EA_PROTOCOL)
        except iap2.Iap2Error as e:
            self.host.close()
            raise SystemExit(f"iAP2 session failed: {e}")
        if verbose:
            i = self.host.ident
            print(f"# iAP2: {i.get('model')} sn={i.get('serial')} fw={i.get('firmware')} "
                  f"protocols={i.get('protocols')}", file=sys.stderr)

    def close(self):
        try:
            self.host.close()
            self.iap2.usb.util.release_interface(self.dev, IAP_INTERFACE)
        except Exception:
            pass

    def send(self, frame):
        if self.verbose:
            print("TX", frame.hex(), file=sys.stderr)
        self.host.send(frame)
        return len(frame)

    def recv(self, seconds):
        out = self.host.poll(seconds)
        if self.verbose:
            for d in out:
                print("RX", d.hex(), file=sys.stderr)
        return out


class BridgeLink:
    """Same interface as Link, but goes through ./boyabridge.

    The bridge asks IOUSBLib to seize *only* interface 0, which would leave the
    receiver's USB-audio interfaces attached.  On macOS 26 the kernel refuses
    this with kIOReturnExclusiveAccess because AppleUserHIDDevice holds the
    interface, so this transport does not currently work - it is kept because
    the approach is sound on other interfaces/OS versions.
    """

    def __init__(self, path=None, verbose=False):
        import subprocess, select, os
        self.select = select
        self.verbose = verbose
        exe = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "boyabridge")
        if not os.path.exists(exe):
            raise SystemExit(f"{exe} not built - run: cc -O2 -o boyabridge "
                             "boyabridge.c -framework IOKit -framework CoreFoundation")
        self.proc = subprocess.Popen([exe], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, bufsize=0)
        deadline = time.time() + 5
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise SystemExit("boyabridge exited (needs sudo?)")
            if line.startswith(b"# ready"):
                return
            if verbose:
                print(line.decode(errors="replace").rstrip(), file=sys.stderr)
        raise SystemExit("boyabridge did not become ready")

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()

    def send(self, frame):
        if self.verbose:
            print("TX", frame.hex(), file=sys.stderr)
        self.proc.stdin.write(frame.hex().encode() + b"\n")
        self.proc.stdin.flush()
        return len(frame)

    def recv(self, seconds):
        out, t = [], time.time()
        while time.time() - t < seconds:
            r, _, _ = self.select.select([self.proc.stdout], [], [],
                                         max(0.0, seconds - (time.time() - t)))
            if not r:
                break
            line = self.proc.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line or line.startswith(b"#"):
                continue
            try:
                data = bytes.fromhex(line.decode())
            except ValueError:
                continue
            if self.verbose:
                print("RX", data.hex(), file=sys.stderr)
            out.append(data)
        return out


class Reassembler:
    """A CFD frame can be longer than one 64-byte USB packet (a full attribute
    dump is ~127 bytes), so rebuild frames from the byte stream the way
    cfdl_io_in() does rather than treating each packet as a frame."""

    MAX_PAYLOAD = 0x480

    def __init__(self):
        self.buf = bytearray()

    def feed(self, chunk):
        self.buf += chunk
        frames = []
        while True:
            # resync on the 0x55 / 0x1X header (inter-frame padding is zeros)
            while len(self.buf) >= 2 and not (
                    self.buf[0] == 0x55 and (self.buf[1] & 0xF0) == 0x10):
                del self.buf[0]
            if len(self.buf) < 17:
                break
            ln = int.from_bytes(self.buf[2:4], "little")
            if ln > self.MAX_PAYLOAD:
                del self.buf[0]
                continue
            total = 17 + ln
            if len(self.buf) < total:
                break
            frame = bytes(self.buf[:total])
            del self.buf[:total]
            if sum(frame[:-1]) & 0xFF == frame[-1]:
                frames.append(frame)
        return frames


class Session:
    """Keeps the CFD-Link router alive and does request/response exchanges.

    The receiver only talks while heartbeats are flowing, so every read also
    answers any heartbeat that arrives - this mirrors cfdl_ro_heartbeat() in
    the SDK.
    """

    def __init__(self, link):
        self.link = link
        self.seq = 1
        self.peers = {}
        self.t0 = time.time()
        self.next_hb = 0.0
        self.rx = Reassembler()

    def _next(self):
        self.seq = (self.seq + 1) & 0xFFFF
        return self.seq

    def _hb_payload(self):
        tick = int((time.time() - self.t0) * 1000) & 0xFFFFFFFF
        return (bytes([0x00]) + struct.pack("<I", 0x01000400) + bytes([0x09])
                + struct.pack("<I", tick) + struct.pack("<H", 0) + bytes([0x24]))

    def beat(self, force=False):
        now = time.time() - self.t0
        if force or now >= self.next_hb:
            self.next_hb = now + 0.5
            self.link.send(build(MSG_HEARTBEAT, self._hb_payload(), seq=self._next()))

    def pump(self, seconds, echo=None):
        out, t = [], time.time()
        while time.time() - t < seconds:
            self.beat()
            frames = []
            for pkt in self.link.recv(0.15):
                frames += self.rx.feed(pkt)
            for f in frames:
                p = parse(f)
                if p and p["src"] != DEVICE_NODE:
                    continue                      # the router hands our own frames back
                if p and p["port"] in HEARTBEAT_SVCS and p["msg_id"] == MSG_HEARTBEAT:
                    self.peers.setdefault((p["chid"], p["vid"], p["pid"]), p)
                    self.link.send(build(MSG_HEARTBEAT, self._hb_payload(),
                                         chid=p["chid"], vid=p["vid"], pid=p["pid"],
                                         seq=self._next(), src=p["dst"], dst=p["src"],
                                         port=p["port"]))
                    continue
                if echo and bytes(f)[:len(echo)] == echo:
                    continue                      # our own frame bounced back
                out.append(f)
        return out

    def handshake(self, seconds=3.0):
        self.beat(force=True)
        self.pump(seconds)

    def req(self, msg_id, payload, target, wait=0.9):
        chid, vid, pid = target
        frame = build(msg_id, payload, chid=chid, vid=vid, pid=pid, seq=self._next())
        self.link.send(frame)
        for f in self.pump(wait, echo=frame):
            p = parse(f)
            if p and p["msg_id"] == msg_id:
                return p
        return None


def print_attr_rows(payload):
    rows = decode_attrs(payload)
    if payload and payload[0] != 0:
        aid = payload[1] if len(payload) > 1 else None
        who = f" for {attr_name(aid)}" if aid is not None else ""
        print(f"device returned status {payload[0]}{who} "
              f"(attribute not available right now - e.g. a TX-side setting "
              f"while that transmitter is not connected)")
        return
    for aid, val in rows:
        print(f"{aid:3d}  0x{aid:02X}  {attr_name(aid):<22} {fmt_value(aid, val)}")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--target", default=None, help="chid,vid,pid (default 1,2,29)")
    ap.add_argument("--transport", choices=("iap", "libusb", "bridge"), default="iap",
                    help="iap (default): iAP2/External-Accessory session on the receiver's "
                         "iAP interface - no sudo, audio keeps working; libusb: raw frames "
                         "on the HID interface, captures the whole device (sudo on macOS); "
                         "bridge: IOUSBLib seize experiment, refused by macOS")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("attrs", help="list attribute names and ids")
    sub.add_parser("getall", help="read every attribute the receiver reports")
    sub.add_parser("peers", help="show CFD-Link nodes and how they describe themselves")
    g = sub.add_parser("get", help="read one attribute")
    g.add_argument("attr")
    s = sub.add_parser("set", help="write one attribute")
    s.add_argument("attr")
    s.add_argument("value", type=lambda x: int(x, 0))
    s.add_argument("--force", action="store_true",
                   help="allow writing an attribute with side effects")
    m = sub.add_parser("monitor", help="print everything the receiver pushes")
    m.add_argument("--seconds", type=float, default=30.0)
    a = ap.parse_args()

    if a.cmd == "attrs":
        for k in sorted(ATTRS):
            nm, rng, labels = ATTRS[k]
            extra = f"{rng[0]}..{rng[1]}" if rng else ""
            if labels:
                extra += "   " + ", ".join(f"{v}={l}" for v, l in labels.items())
            if k in RISKY:
                extra += f"   [!] {RISKY[k]}"
            print(f"{k:3d}  0x{k:02X}  {nm:<22} {extra}")
        return

    target = tuple(int(x, 0) for x in a.target.split(",")) if a.target else DEFAULT_TARGET
    link = {"iap": IapLink, "libusb": Link, "bridge": BridgeLink}[a.transport](verbose=a.verbose)
    try:
        sess = Session(link)
        sess.handshake(3.0)

        if a.cmd == "peers":
            print("heartbeat peers (chid, vid, pid):", list(sess.peers) or "none")
            for node in sorted(set(list(sess.peers) + [DEFAULT_TARGET])):
                if node[1:] == (0, 0):
                    continue
                p = sess.req(MSG_DEVICE_DES, b"", node, wait=0.5)
                if not p:
                    print(f"  {node}: no describe reply")
                    continue
                pl = p["payload"]
                recs = [(pl[i], int.from_bytes(pl[i + 1:i + 5], "big"))
                        for i in range(2, len(pl) - 4, 5)]
                caps = dict(recs).get(15, 0)
                print(f"  {node}: " + " ".join(f"des{i}={v}" for i, v in recs)
                      + f"   [old_attr_api={bool(caps & 1)} "
                        f"no_attrs={bool(caps & 2)} attr_by_id={bool(caps & 4)}]")

        elif a.cmd == "getall":
            p = sess.req(MSG_GET_MANY, bytes([0]), target, wait=1.5)
            if not p:
                raise SystemExit("no reply - try --target, or check the receiver is awake")
            print_attr_rows(p["payload"])

        elif a.cmd == "get":
            p = sess.req(MSG_GET_ATTR, bytes([attr_id(a.attr)]), target)
            if not p:
                raise SystemExit("no reply")
            print_attr_rows(p["payload"])

        elif a.cmd == "set":
            aid = attr_id(a.attr)
            rng = ATTRS.get(aid, ("?", None, None))[1]
            if rng and not (rng[0] <= a.value <= rng[1]):
                raise SystemExit(f"{attr_name(aid)} takes {rng[0]}..{rng[1]}")
            if aid in RISKY and not a.force:
                raise SystemExit(f"{attr_name(aid)}: {RISKY[aid]} - pass --force")
            sess.req(MSG_SET_ATTR, bytes([aid, 1, a.value & 0xFF]), target, wait=0.6)
            p = sess.req(MSG_GET_ATTR, bytes([aid]), target)
            if not p:
                print("set sent, but read-back got no reply")
            else:
                print_attr_rows(p["payload"])

        elif a.cmd == "monitor":
            t = time.time()
            while time.time() - t < a.seconds:
                for f in sess.pump(1.0):
                    p = parse(f)
                    if not p:
                        print("raw", bytes(f).hex())
                        continue
                    extra = " ".join(f"{attr_name(i)}={fmt_value(i, v)}"
                                     for i, v in decode_attrs(p["payload"])) \
                        if p["msg_id"] in (MSG_GET_ATTR, MSG_SET_ATTR, MSG_GET_MANY) else ""
                    print(f"chid={p['chid']} vid={p['vid']} pid={p['pid']} "
                          f"msg=0x{p['msg_id']:02X} {extra or p['payload'].hex()}")
    finally:
        link.close()


if __name__ == "__main__":
    main()
