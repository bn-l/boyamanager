#!/usr/bin/env python3
"""
iap2probe - talk iAP2 to the BOYA mini 2 over its *iAP interface* (USB
interface 1, bulk 0x01 OUT / 0x81 IN) instead of the HID interface.

Why: on macOS nothing binds a driver to interface 1, so it can be claimed
without root and without capturing the device - the USB audio keeps working.
The iOS app talks to the receiver exactly this way (EASession, protocol
"BOYA.DeviceLink.com"), with the CFD-Link frames riding inside the External
Accessory session.

We play the part of the iPhone:
  1. iAP2 detect         FF 55 02 00 EE 10  -> accessory echoes it back
  2. link SYN / SYN-ACK / ACK, negotiating a control session and an EA session
  3. control session: StartIdentification -> IdentificationInformation ->
     IdentificationAccepted ; (authentication is optional for us - we are the
     side that would verify the accessory, and we don't care)
  4. StartExternalAccessoryProtocolSession(protocol id, session id)
  5. CFD frames in EA session packets: [ea session id u16 BE][cfd frame]
"""
import struct, sys, time, random, argparse
import usb.core, usb.util

VID, PID = 0x2F05, 0x003B
IFACE = 1
EP_OUT, EP_IN = 0x01, 0x81

SYN, ACK, EAK, RST, SLP = 0x80, 0x40, 0x20, 0x10, 0x08
SESS_CTRL, SESS_EA = 0x0A, 0x0B

MSG = {
    0x1D00: 'StartIdentification', 0x1D01: 'IdentificationInformation',
    0x1D02: 'IdentificationAccepted', 0x1D03: 'IdentificationRejected',
    0x1D05: 'CancelIdentification', 0x1D06: 'IdentificationInformationUpdate',
    0xAA00: 'RequestAuthenticationCertificate', 0xAA01: 'AuthenticationCertificate',
    0xAA02: 'RequestAuthenticationChallengeResponse', 0xAA03: 'AuthenticationResponse',
    0xAA04: 'AuthenticationFailed', 0xAA05: 'AuthenticationSucceeded',
    0xAA06: 'AccessoryAuthenticationSerialNumber',
    0xEA00: 'StartExternalAccessoryProtocolSession',
    0xEA01: 'StopExternalAccessoryProtocolSession', 0xEA02: 'RequestAppLaunch',
    0xEA03: 'StatusExternalAccessoryProtocolSession',
    0xAE00: 'PowerSourceUpdate', 0xAE01: 'StartPowerUpdates', 0xAE02: 'PowerUpdate',
    0xAE03: 'StopPowerUpdates',
    0x6800: 'StartHID', 0x6801: 'DeviceHIDReport', 0x6802: 'AccessoryHIDReport', 0x6803: 'StopHID',
    0xDA00: 'StartUSBDeviceModeAudio', 0xDA01: 'USBDeviceModeAudioInformation', 0xDA02: 'StopUSBDeviceModeAudio',
    0xFFFA: 'DeviceInformationUpdate', 0x4E00: 'RequestWiFiInformation',
}
IDENT_PARAM = {0: 'Name', 1: 'ModelIdentifier', 2: 'Manufacturer', 3: 'SerialNumber',
               4: 'FirmwareVersion', 5: 'HardwareVersion', 6: 'MessagesSentByAccessory',
               7: 'MessagesReceivedFromDevice', 8: 'PowerProvidingCapability',
               9: 'MaximumCurrentDrawnFromDevice', 10: 'SupportedExternalAccessoryProtocol',
               11: 'AppMatchTeamID', 12: 'CurrentLanguage', 13: 'SupportedLanguage',
               14: 'SerialTransportComponent', 15: 'USBDeviceTransportComponent',
               16: 'USBHostTransportComponent', 17: 'BluetoothTransportComponent',
               18: 'iAP2HIDComponent', 19: 'VehicleInformationComponent',
               20: 'VehicleStatusComponent', 21: 'LocationInformationComponent',
               22: 'USBHostHIDComponent', 23: 'WirelessCarPlayTransportComponent',
               24: 'BluetoothHIDComponent', 25: 'ProductPlanUUID'}


def hexs(b): return bytes(b).hex()


# ----------------------------------------------------------------- link layer
def lpkt(ctrl, seq, ack, sess, payload=b''):
    length = 9 + (len(payload) + 1 if payload else 0)
    hdr = b'\xff\x5a' + struct.pack('>H', length) + bytes([ctrl, seq & 0xFF, ack & 0xFF, sess])
    hdr += bytes([(-sum(hdr)) & 0xFF])
    if payload:
        return hdr + payload + bytes([(-sum(payload)) & 0xFF])
    return hdr


class LinkParser:
    def __init__(self): self.buf = bytearray()

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(b'\xff\x5a')
            if i < 0:
                if len(self.buf) >= 6 and self.buf[:2] == b'\xff\x55':   # detect echo
                    out.append(('detect', bytes(self.buf[:6]))); del self.buf[:6]; continue
                self.buf = self.buf[-1:] if self.buf[-1:] == b'\xff' else bytearray()
                break
            if i:
                pre = bytes(self.buf[:i]); del self.buf[:i]
                if pre.startswith(b'\xff\x55'): out.append(('detect', pre))
                else: out.append(('junk', pre))
            if len(self.buf) < 9: break
            if sum(self.buf[:9]) & 0xFF:                 # bad header checksum
                del self.buf[:2]; continue
            length = struct.unpack('>H', self.buf[2:4])[0]
            if length < 9: del self.buf[:2]; continue
            if len(self.buf) < length: break
            pkt = bytes(self.buf[:length]); del self.buf[:length]
            payload = pkt[9:-1] if length > 9 else b''
            if length > 9 and sum(pkt[9:]) & 0xFF:
                out.append(('badpayload', pkt)); continue
            out.append(('pkt', dict(ctrl=pkt[4], seq=pkt[5], ack=pkt[6], sess=pkt[7], payload=payload)))
        return out


# ----------------------------------------------------------- control session
def cmsg(mid, params=b''):
    return b'\x40\x40' + struct.pack('>HH', 6 + len(params), mid) + params


def param(pid, data=b''):
    return struct.pack('>HH', 4 + len(data), pid) + data


def parse_params(b):
    out, i = [], 0
    while i + 4 <= len(b):
        ln, pid = struct.unpack('>HH', b[i:i + 4])
        if ln < 4 or i + ln > len(b): break
        out.append((pid, b[i + 4:i + ln])); i += ln
    return out


def parse_cmsg(b):
    if len(b) < 6 or b[:2] != b'\x40\x40': return None
    ln, mid = struct.unpack('>HH', b[2:6])
    return mid, parse_params(b[6:ln])


# ------------------------------------------------------------------ CFD-Link
def cfd(msg_id, payload=b'', chid=0, vid=0, pid=0, seq=1, src=2, dst=1, svc=0x1D):
    body = (bytes([0x55, 0x10]) + struct.pack('<HH', len(payload), seq) + bytes([src, dst])
            + struct.pack('<H', svc) + bytes([chid, vid]) + struct.pack('<HH', pid, msg_id) + payload)
    return body + bytes([sum(body) & 0xFF])


def cfd_parse(f):
    if len(f) < 17 or f[0] != 0x55: return None
    ln, seq = struct.unpack_from('<HH', f, 2)
    pid, msg = struct.unpack_from('<HH', f, 12)
    return dict(seq=seq, src=f[6], dst=f[7], svc=struct.unpack_from('<H', f, 8)[0],
                chid=f[10], vid=f[11], pid=pid, msg=msg, payload=f[16:16 + ln])


class CfdReasm:
    def __init__(self): self.buf = bytearray()

    def feed(self, chunk):
        self.buf += chunk; out = []
        while True:
            while len(self.buf) >= 2 and not (self.buf[0] == 0x55 and (self.buf[1] & 0xF0) == 0x10):
                del self.buf[0]
            if len(self.buf) < 17: break
            ln = int.from_bytes(self.buf[2:4], 'little')
            if ln > 0x480: del self.buf[0]; continue
            if len(self.buf) < 17 + ln: break
            f = bytes(self.buf[:17 + ln]); del self.buf[:17 + ln]
            if sum(f[:-1]) & 0xFF == f[-1]: out.append(f)
        return out


# --------------------------------------------------------------------- host
class Host:
    def __init__(self, verbose=True):
        self.v = verbose
        dev = usb.core.find(idVendor=VID, idProduct=PID)
        if dev is None: raise SystemExit('receiver not found')
        usb.util.claim_interface(dev, IFACE)
        self.dev = dev
        self.lp = LinkParser()
        self.seq = random.randrange(1, 200)   # our link seq
        self.rack = 0                          # last seq received from accessory (what we ack)
        self.their_ack = None
        self.linked = False
        self.syn_reply = None
        self.sess_ctrl, self.sess_ea = SESS_CTRL, SESS_EA
        self.ea_proto_id = None
        self.ea_sess_id = None
        self.ea_open = False
        self.ident = {}
        self.cfd = CfdReasm()
        self.cfd_seq = 1
        self.t0 = time.time()
        self.frames = []
        self.last_rx_seq = None
        self.outq = []

    def close(self):
        try: usb.util.release_interface(self.dev, IFACE)
        except Exception: pass

    # -- raw io
    def write(self, data):
        if self.v: print(f'  >> {hexs(data)}')
        self.dev.write(EP_OUT, data, timeout=500)

    def read_some(self, timeout_ms=20):
        try:
            d = bytes(self.dev.read(EP_IN, 64, timeout=timeout_ms))
        except usb.core.USBTimeoutError:
            return b''
        except usb.core.USBError as e:
            if getattr(e, 'errno', None) == 60 or 'timed out' in str(e).lower(): return b''
            raise
        if d and self.v: print(f'  << {hexs(d)}')
        return d

    # -- link
    def send_ack(self):
        self.write(lpkt(ACK, self.seq, self.rack, 0))

    def send_data(self, sess, payload, wait=1.0, retries=3):
        self.seq = (self.seq + 1) & 0xFF
        pkt = lpkt(ACK, self.seq, self.rack, sess, payload)
        for attempt in range(retries):
            self.write(pkt)
            t = time.time()
            while time.time() - t < wait:
                self.pump(20)
                if self.their_ack == self.seq: return True
        print(f'!! no ACK for seq {self.seq}')
        return False

    def pump(self, timeout_ms=20):
        d = self.read_some(timeout_ms)
        if not d: return
        for kind, item in self.lp.feed(d):
            if kind == 'detect':
                print(f'[detect reply] {hexs(item)}'); self.detect_ok = True; continue
            if kind != 'pkt':
                print(f'[{kind}] {hexs(item)}'); continue
            self.on_pkt(item)

    def on_pkt(self, p):
        c = p['ctrl']
        if c & ACK: self.their_ack = p['ack']
        if c & SYN:
            self.syn_reply = p; self.rack = p['seq']
            print(f'[SYN{"+ACK" if c & ACK else ""}] seq={p["seq"]} ack={p["ack"]} payload={hexs(p["payload"])}')
            self.parse_syn(p['payload'])
            return
        if c & RST:
            print('[RST] accessory reset the link'); self.linked = False; return
        if not p['payload']:
            if self.v: print(f'[ACK] ack={p["ack"]}')
            return
        # data packet: ack it, dedupe retransmissions
        dup = (p['seq'] == self.last_rx_seq)
        self.last_rx_seq = p['seq']; self.rack = p['seq']
        self.send_ack()
        if dup: return
        if p['sess'] == self.sess_ctrl: self.on_ctrl(p['payload'])
        elif p['sess'] == self.sess_ea: self.on_ea(p['payload'])
        else: print(f'[sess {p["sess"]}] {hexs(p["payload"])}')

    def parse_syn(self, pl):
        if len(pl) < 10: return
        print(f'   link ver={pl[0]} maxOutstanding={pl[1]} maxPktLen={struct.unpack(">H", pl[2:4])[0]} '
              f'retransTO={struct.unpack(">H", pl[4:6])[0]} cumAckTO={struct.unpack(">H", pl[6:8])[0]} '
              f'maxRetrans={pl[8]} maxCumAck={pl[9]}')
        for i in range(10, len(pl) - 2, 3):
            print(f'   session id={pl[i]:#04x} type={pl[i + 1]} ver={pl[i + 2]}')

    # -- control session
    def send_ctrl(self, mid, params=b''):
        print(f'-> {MSG.get(mid, hex(mid))}')
        return self.send_data(self.sess_ctrl, cmsg(mid, params))

    def on_ctrl(self, pl):
        m = parse_cmsg(pl)
        if not m: print(f'[ctrl junk] {hexs(pl)}'); return
        mid, params = m
        print(f'<- {MSG.get(mid, hex(mid))}')
        if mid == 0x1D01:      # IdentificationInformation
            for pid, data in params:
                name = IDENT_PARAM.get(pid, str(pid))
                if pid == 10:
                    sub = dict(parse_params(data))
                    proto_id = sub.get(0, b'\0')[0]; pname = sub.get(1, b'').rstrip(b'\0').decode(errors='replace')
                    print(f'   {name}: id={proto_id} name={pname!r} match={sub.get(2, b"?").hex()} '
                          f'nativeTransport={sub.get(3, b"").hex()}')
                    if 'BOYA' in pname or self.ea_proto_id is None: self.ea_proto_id = proto_id; self.ea_proto_name = pname
                elif pid in (6, 7):
                    ids = [struct.unpack('>H', data[i:i + 2])[0] for i in range(0, len(data) - 1, 2)]
                    print(f'   {name}: ' + ', '.join(MSG.get(i, hex(i)) for i in ids))
                elif pid in (0, 1, 2, 3, 4, 5, 11, 12, 13):
                    print(f'   {name}: {data.rstrip(b"\0").decode(errors="replace")!r}')
                else:
                    print(f'   {name}: {data.hex()}')
            self.ident_ok = True
        elif mid == 0xAA01:    # AuthenticationCertificate
            self.have_cert = True
        elif mid == 0xAA03:    # AuthenticationResponse
            self.have_auth_resp = True
        elif mid == 0xEA03:    # StatusExternalAccessoryProtocolSession
            for pid, data in params: print(f'   param {pid}: {data.hex()}')
        else:
            for pid, data in params: print(f'   param {pid}: {data.hex()}')

    # -- EA session
    def on_ea(self, pl):
        sid = struct.unpack('>H', pl[:2])[0]; data = pl[2:]
        if self.v: print(f'[EA sid={sid}] {hexs(data)}')
        for f in self.cfd.feed(data):
            p = cfd_parse(f)
            if p['src'] != 1:
                # the router hands our own frames back (payload tweaked) - not for us
                if self.v: print(f'   (echo of host frame seq={p["seq"]} msg={p["msg"]:#04x})')
                continue
            print(f'   CFD src={p["src"]} dst={p["dst"]} svc={p["svc"]:#x} node=({p["chid"]},{p["vid"]},{p["pid"]}) '
                  f'msg={p["msg"]:#04x} payload={hexs(p["payload"])}')
            self.frames.append(p)
            if p['msg'] == 0 and p['svc'] in (0x1D, 0x1E):   # heartbeat from the device -> answer it
                self.outq.append(cfd(0, self.hb(), chid=p['chid'], vid=p['vid'], pid=p['pid'],
                                     seq=self.next_cfd(), src=p['dst'], dst=p['src'], svc=p['svc']))

    def next_cfd(self):
        self.cfd_seq = (self.cfd_seq + 1) & 0xFFFF; return self.cfd_seq

    def hb(self):
        tick = int((time.time() - self.t0) * 1000) & 0xFFFFFFFF
        return bytes([0]) + struct.pack('<I', 0x01000400) + bytes([9]) + struct.pack('<IH', tick, 0) + bytes([0x24])

    def send_cfd(self, frame):
        if self.v: print(f'-> CFD {hexs(frame)}')
        return self.send_data(self.sess_ea, struct.pack('>H', self.ea_sess_id) + frame)

    def drain(self):
        while self.outq:
            self.send_cfd(self.outq.pop(0))

    def request(self, msg_id, payload, node, wait=1.5):
        """Send one CFD request to a node and wait for the reply with the same msg_id."""
        chid, vid, pid = node
        n = len(self.frames)
        self.outq.append(cfd(msg_id, payload, chid=chid, vid=vid, pid=pid, seq=self.next_cfd()))
        t = time.time()
        while time.time() - t < wait:
            self.drain(); self.pump(20)
            for p in self.frames[n:]:
                if p['msg'] == msg_id: return p
        return None

    # -- flows
    def detect(self):
        self.detect_ok = False
        # flush anything stale
        for _ in range(20):
            if not self.read_some(10): break
        for attempt in range(3):
            self.write(b'\xff\x55\x02\x00\xee\x10')
            t = time.time()
            while time.time() - t < 1.0:
                self.pump(50)
                if self.detect_ok: return True
        return False

    def link(self):
        # iAP2 roles: the ACCESSORY sends detect and then SYN; the Apple device
        # (us) answers the detect with the same bytes and the SYN with SYN|ACK
        # carrying the accepted link parameters.  The accessory then ACKs.
        for attempt in range(4):
            if self.syn_reply: break
            self.write(b'\xff\x55\x02\x00\xee\x10')
            self.wait(1.0, lambda: self.syn_reply is not None)
        if not self.syn_reply: return False
        p = self.syn_reply; pl = p['payload']
        sessions = [(pl[i], pl[i + 1]) for i in range(10, len(pl) - 2, 3)]
        self.sess_ctrl = next((i for i, t in sessions if t == 0), SESS_CTRL)
        self.sess_ea = next((i for i, t in sessions if t == 2), SESS_EA)
        self.rack = p['seq']
        self.their_ack = None
        for attempt in range(3):
            self.write(lpkt(SYN | ACK, self.seq, self.rack, 0, pl))   # accept its parameters verbatim
            if self.wait(1.5, lambda: self.their_ack == self.seq): break
        print(f'link: ctrl session={self.sess_ctrl} ea session={self.sess_ea} their_ack={self.their_ack}')
        self.linked = True
        return True

    def wait(self, secs, cond=lambda: False):
        t = time.time()
        while time.time() - t < secs:
            self.pump(20)
            if cond(): return True
        return cond()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-q', '--quiet', action='store_true')
    ap.add_argument('--auth', action='store_true', help='also run the (pointless for us) authentication flow')
    ap.add_argument('--seconds', type=float, default=8.0)
    a = ap.parse_args()
    h = Host(verbose=not a.quiet)
    try:
        print('== link (answer the accessory\'s detect + SYN)'); print('link:', h.link())
        if not h.linked: return
        h.ident_ok = False
        print('== identification')
        h.send_ctrl(0x1D00)
        h.wait(3.0, lambda: h.ident_ok)
        if not h.ident_ok: print('no IdentificationInformation'); return
        h.send_ctrl(0x1D02)
        if a.auth:
            h.have_cert = h.have_auth_resp = False
            h.send_ctrl(0xAA00); h.wait(3.0, lambda: h.have_cert)
            h.send_ctrl(0xAA02, param(0, bytes(random.randrange(256) for _ in range(20))))
            h.wait(3.0, lambda: h.have_auth_resp)
            h.send_ctrl(0xAA05)
        h.wait(0.5)
        print(f'== EA session for protocol id {h.ea_proto_id} ({getattr(h, "ea_proto_name", "?")})')
        h.ea_sess_id = 1
        h.send_ctrl(0xEA00, param(0, bytes([h.ea_proto_id])) + param(1, struct.pack('>H', h.ea_sess_id)))
        h.wait(0.5)
        print('== CFD heartbeats over EA')
        t = time.time()
        while time.time() - t < 2.0:                       # let the heartbeat exchange settle
            h.outq.append(cfd(0, h.hb(), seq=h.next_cfd()))
            tt = time.time()
            while time.time() - tt < 0.5:
                h.drain(); h.pump(20)
        node = (1, 2, 29)
        print('== describe', node)
        p = h.request(0x15, b'', node)
        print('   ', hexs(p['payload']) if p else 'no reply')
        print('== get nc (47)')
        p = h.request(0x1F, bytes([47]), node)
        print('   ', hexs(p['payload']) if p else 'no reply')
        print('== get all')
        p = h.request(0x21, bytes([0]), node, wait=2.5)
        if p:
            pl = p['payload']; i = 1
            print(f'    status={pl[0]}')
            while i + 1 < len(pl):
                aid, ln = pl[i], pl[i + 1]; val = pl[i + 2:i + 2 + ln]
                if ln == 0 or len(val) < ln: break
                print(f'    attr {aid:3d} 0x{aid:02X} = {val.hex()}'); i += 2 + ln
        else:
            print('    no reply')
        print(f'== done, {len(h.frames)} CFD frames received from the device')
        h.send_ctrl(0xEA01, param(0, struct.pack('>H', h.ea_sess_id)))   # StopExternalAccessoryProtocolSession
        h.wait(0.3)
    finally:
        h.close()


if __name__ == '__main__':
    main()
