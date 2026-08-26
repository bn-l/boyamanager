#!/usr/bin/env python3
"""
svc_test - does the receiver care about the CFD-Link `svc` field (offset 8) and
the host link address (`src`, offset 6)?

The Android SDK stamps svc=0x1D, the iOS SDK stamps svc=0x1B; the iOS SDK also
starts with src=1 (same as the device) and only moves to a random address after
a collision.  BOYAMIC_PROTOCOL.md claims "svc 0x1B => silence" from a USB test
that used src=1, so the two variables were confounded.  This sends heartbeats +
a `get nc` with each combination over the iAP transport and counts replies.

    .venv/bin/python scripts/svc_test.py
"""
import os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iap2

VID, PID = 0x2F05, 0x003B
NODE = (1, 2, 29)


def cfd(msg_id, payload=b'', chid=0, vid=0, pid=0, seq=1, src=2, dst=1, svc=0x1D):
    body = (bytes([0x55, 0x10]) + struct.pack('<HH', len(payload), seq) + bytes([src, dst])
            + struct.pack('<H', svc) + bytes([chid, vid]) + struct.pack('<HH', pid, msg_id) + payload)
    return body + bytes([sum(body) & 0xFF])


def frames(chunks, buf):
    buf += b''.join(chunks)
    out = []
    while True:
        while len(buf) >= 2 and not (buf[0] == 0x55 and (buf[1] & 0xF0) == 0x10):
            del buf[0]
        if len(buf) < 17:
            return out
        ln = int.from_bytes(buf[2:4], 'little')
        if ln > 0x480:
            del buf[0]; continue
        if len(buf) < 17 + ln:
            return out
        f = bytes(buf[:17 + ln]); del buf[:17 + ln]
        if sum(f[:-1]) & 0xFF == f[-1]:
            out.append(f)


def hb(t0):
    tick = int((time.time() - t0) * 1000) & 0xFFFFFFFF
    return bytes([0]) + struct.pack('<I', 0x01000400) + bytes([9]) + struct.pack('<IH', tick, 0) + bytes([0x24])


def trial(h, svc, src, seconds=3.0, gets=(1.0, 2.0)):
    """Heartbeat with (svc, src) for `seconds`, sending `get nc` at the given
    offsets.  Returns (device heartbeats seen, get replies, sample reply)."""
    t0 = time.time(); seq = 0; buf = bytearray()
    dev_hb = replies = 0; last = 0; sent = 0
    got = None
    while time.time() - t0 < seconds:
        if time.time() - last > 0.5:
            last = time.time(); seq += 1
            h.send(cfd(0, hb(t0), seq=seq, src=src, svc=svc))
        if sent < len(gets) and time.time() - t0 >= gets[sent]:
            sent += 1; seq += 1
            h.send(cfd(0x1F, bytes([47]), *NODE, seq=seq, src=src, svc=svc))
        for f in frames(h.poll(0.1), buf):
            if f[6] == src:
                continue        # our own frame handed back (with src=1 this also hides device frames)
            msg = struct.unpack_from('<H', f, 14)[0]; fsvc = struct.unpack_from('<H', f, 8)[0]
            if msg == 0:
                dev_hb += 1
                seq += 1        # answer it, with the svc/src under test
                h.send(cfd(0, hb(t0), chid=f[10], vid=f[11], pid=struct.unpack_from('<H', f, 12)[0],
                           seq=seq, src=src, dst=f[6], svc=svc))
            elif msg == 0x1F:
                replies += 1; got = (fsvc, f[16:16 + 4].hex())
    return dev_hb, replies, got


def main():
    dev = iap2.claim(VID, PID, 1)
    h = iap2.Iap2Host(dev)
    try:
        h.open('BOYA.DeviceLink.com')
        print('warm-up (svc 0x1D, src 2):', trial(h, 0x1D, 2, seconds=3.0, gets=()))
        for svc, src in ((0x1B, 2), (0x1D, 2), (0x00, 2), (0x1E, 2), (0x1B, 2), (0x1D, 1), (0x1B, 1), (0x1D, 3), (0x1D, 2)):
            dev_hb, replies, got = trial(h, svc, src)
            print(f'svc=0x{svc:02X} src={src}: heartbeats from device={dev_hb:2d}  '
                  f'get-nc replies={replies}/2  {got or ""}')
    finally:
        h.close()
        iap2.usb.util.release_interface(dev, 1)


if __name__ == '__main__':
    main()
