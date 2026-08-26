#!/usr/bin/env python3
"""
iap2 - a minimal iAP2 *host* (the Apple-device side of the protocol) over USB,
just enough to open an External Accessory (EA) session on an MFi accessory
and move bytes through it.

Written for the BOYA mini 2 receiver, whose USB interface 1 ("iAP Interface",
class 0xFF / subclass 0xF0, bulk 0x01 OUT / 0x81 IN) carries iAP2.  On macOS no
driver binds that interface, so it can be claimed by a normal user without
capturing the device: the receiver's USB-audio keeps working and no sudo is
needed.  BOYA's own iOS app talks to the receiver exactly this way (EASession,
protocol "BOYA.DeviceLink.com") with CFD-Link frames riding inside.

Protocol summary (verified against the receiver):

  detect      accessory -> host   FF 55 02 00 EE 10   (the accessory initiates)
              host -> accessory   FF 55 02 00 EE 10   (echo it back)
  link SYN    accessory -> host   link params + session list
              host -> accessory   SYN|ACK with the accepted params (echo theirs)
              accessory -> host   ACK
  control     host: StartIdentification(0x1D00)
              accessory: IdentificationInformation(0x1D01) - name, serial,
                         firmware, EA protocol ids/names, ...
              host: IdentificationAccepted(0x1D02)
              host: StartExternalAccessoryProtocolSession(0xEA00,
                    protocol id, session id)
              accessory: StatusExternalAccessoryProtocolSession(0xEA03)
  EA data     link packet on the EA session; payload = u16 BE session id + data

Link packet: FF 5A | u16 BE total length | ctrl | seq | ack | session |
             header checksum (sum of the 9 header bytes == 0 mod 256) |
             payload | payload checksum (sum of payload bytes == 0 mod 256)
Control msg: 40 40 | u16 BE total length | u16 BE message id |
             params (u16 BE length incl. 4-byte header, u16 BE id, data)*
Authentication (the MFi coprocessor dance) is what the *accessory* proves to
the *host*; as the host we simply don't ask.
"""
import random
import struct
import sys
import time

import usb.core
import usb.util

SYN, ACK, EAK, RST, SLP = 0x80, 0x40, 0x20, 0x10, 0x08
DETECT = b'\xff\x55\x02\x00\xee\x10'

MSG_START_IDENT = 0x1D00
MSG_IDENT_INFO = 0x1D01
MSG_IDENT_ACCEPTED = 0x1D02
MSG_START_EA = 0xEA00
MSG_STOP_EA = 0xEA01
MSG_EA_STATUS = 0xEA03

MSG_NAMES = {
    0x1D00: 'StartIdentification', 0x1D01: 'IdentificationInformation',
    0x1D02: 'IdentificationAccepted', 0x1D03: 'IdentificationRejected',
    0x1D05: 'CancelIdentification', 0x1D06: 'IdentificationInformationUpdate',
    0xAA00: 'RequestAuthenticationCertificate', 0xAA01: 'AuthenticationCertificate',
    0xAA02: 'RequestAuthenticationChallengeResponse', 0xAA03: 'AuthenticationResponse',
    0xAA04: 'AuthenticationFailed', 0xAA05: 'AuthenticationSucceeded',
    0xEA00: 'StartExternalAccessoryProtocolSession',
    0xEA01: 'StopExternalAccessoryProtocolSession', 0xEA02: 'RequestAppLaunch',
    0xEA03: 'StatusExternalAccessoryProtocolSession',
    0xAE00: 'PowerSourceUpdate', 0xAE01: 'StartPowerUpdates', 0xAE02: 'PowerUpdate',
    0xAE03: 'StopPowerUpdates',
}
IDENT_PARAMS = {0: 'name', 1: 'model', 2: 'manufacturer', 3: 'serial', 4: 'firmware',
                5: 'hardware', 6: 'messages_sent', 7: 'messages_received',
                8: 'power_providing', 9: 'max_current_ma', 10: 'ea_protocol',
                11: 'app_match_team_id', 12: 'language', 13: 'supported_language',
                16: 'usb_host_transport'}


class Iap2Error(Exception):
    pass


# --------------------------------------------------------------- link layer
def link_packet(ctrl, seq, ack, session, payload=b''):
    length = 9 + (len(payload) + 1 if payload else 0)
    hdr = b'\xff\x5a' + struct.pack('>H', length) + bytes([ctrl, seq & 0xFF, ack & 0xFF, session])
    hdr += bytes([(-sum(hdr)) & 0xFF])
    if payload:
        return hdr + payload + bytes([(-sum(payload)) & 0xFF])
    return hdr


class LinkParser:
    """Byte-stream -> ('detect', bytes) | ('pkt', dict) | ('junk', bytes)."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(b'\xff\x5a')
            if i < 0:
                if len(self.buf) >= 6 and self.buf[:2] == b'\xff\x55':
                    out.append(('detect', bytes(self.buf[:6])))
                    del self.buf[:6]
                    continue
                if not (len(self.buf) == 1 and self.buf[0] == 0xFF):
                    if self.buf:
                        out.append(('junk', bytes(self.buf)))
                    self.buf.clear()
                break
            if i:
                pre = bytes(self.buf[:i])
                del self.buf[:i]
                out.append(('detect' if pre.startswith(b'\xff\x55') else 'junk', pre))
            if len(self.buf) < 9:
                break
            if sum(self.buf[:9]) & 0xFF:
                del self.buf[:2]
                continue
            length = struct.unpack('>H', self.buf[2:4])[0]
            if length < 9:
                del self.buf[:2]
                continue
            if len(self.buf) < length:
                break
            pkt = bytes(self.buf[:length])
            del self.buf[:length]
            payload = pkt[9:-1] if length > 9 else b''
            if length > 9 and sum(pkt[9:]) & 0xFF:
                out.append(('junk', pkt))
                continue
            out.append(('pkt', dict(ctrl=pkt[4], seq=pkt[5], ack=pkt[6],
                                    session=pkt[7], payload=payload)))
        return out


# ---------------------------------------------------------- control session
def control_message(msg_id, params=b''):
    return b'\x40\x40' + struct.pack('>HH', 6 + len(params), msg_id) + params


def parameter(pid, data=b''):
    return struct.pack('>HH', 4 + len(data), pid) + data


def parse_parameters(b):
    out, i = [], 0
    while i + 4 <= len(b):
        ln, pid = struct.unpack('>HH', b[i:i + 4])
        if ln < 4 or i + ln > len(b):
            break
        out.append((pid, b[i + 4:i + ln]))
        i += ln
    return out


def parse_control_message(b):
    if len(b) < 6 or b[:2] != b'\x40\x40':
        return None
    ln, msg_id = struct.unpack('>HH', b[2:6])
    return msg_id, parse_parameters(b[6:ln])


def _cstr(b):
    return b.split(b'\0', 1)[0].decode('utf-8', errors='replace')


# -------------------------------------------------------------------- host
class Iap2Host:
    """Drive one accessory over a claimed USB interface.

    usage:
        h = Iap2Host(dev)              # dev: a pyusb device, interface already claimed
        h.open('BOYA.DeviceLink.com')  # link + identification + EA session
        h.send(b'...')                 # data into the EA session (waits for link ACK)
        chunks = h.poll(0.2)           # pump the link for 0.2 s, get EA data chunks
        h.close()
    """

    def __init__(self, dev, ep_out=0x01, ep_in=0x81, packet_size=64, verbose=False, log=None):
        self.dev, self.ep_out, self.ep_in, self.pkt = dev, ep_out, ep_in, packet_size
        self.verbose = verbose
        self.log = log or (lambda s: print(s, file=sys.stderr))
        self.parser = LinkParser()
        self.seq = random.randrange(1, 200)      # our sequence number
        self.rack = 0                            # last accessory seq (what we ack)
        self.their_ack = None
        self.last_rx_seq = None
        self.syn = None
        self.session_ctrl = self.session_ea = None
        self.ident = {}
        self.protocols = []                      # [(id, name)]
        self.ea_session_id = None
        self.ea_status = None
        self.ea_rx = []                          # data chunks received on the EA session
        self.linked = False

    # -- raw usb
    def _write(self, data):
        if self.verbose:
            self.log(f'iap2 >> {bytes(data).hex()}')
        self.dev.write(self.ep_out, data, timeout=500)

    def _read(self, timeout_ms):
        try:
            d = bytes(self.dev.read(self.ep_in, self.pkt, timeout=timeout_ms))
        except usb.core.USBTimeoutError:
            return b''
        except usb.core.USBError as e:
            if getattr(e, 'errno', None) == 60 or 'timed out' in str(e).lower():
                return b''
            raise
        if d and self.verbose:
            self.log(f'iap2 << {d.hex()}')
        return d

    # -- link layer
    def pump(self, timeout_ms=20):
        """Read whatever is pending and handle it (acks, control, EA data)."""
        d = self._read(timeout_ms)
        if not d:
            return
        for kind, item in self.parser.feed(d):
            if kind == 'pkt':
                self._on_packet(item)
            elif kind == 'detect':
                self._write(DETECT)              # the accessory is (re)starting: echo
            elif self.verbose:
                self.log(f'iap2 junk {item.hex()}')

    def _on_packet(self, p):
        c = p['ctrl']
        if c & ACK:
            self.their_ack = p['ack']
        if c & SYN:
            self.syn = p
            self.rack = p['seq']
            return
        if c & RST:
            self.linked = False
            raise Iap2Error('accessory reset the iAP2 link')
        if not p['payload']:
            return                               # bare ACK
        dup = p['seq'] == self.last_rx_seq
        self.last_rx_seq = self.rack = p['seq']
        self._write(link_packet(ACK, self.seq, self.rack, 0))
        if dup:
            return
        if p['session'] == self.session_ctrl:
            self._on_control(p['payload'])
        elif p['session'] == self.session_ea:
            self.ea_rx.append(p['payload'][2:])  # strip the u16 EA session id
        elif self.verbose:
            self.log(f'iap2 session {p["session"]}: {p["payload"].hex()}')

    def _send_data(self, session, payload, wait=1.0, retries=3):
        self.seq = (self.seq + 1) & 0xFF
        pkt = link_packet(ACK, self.seq, self.rack, session, payload)
        for _ in range(retries):
            self._write(pkt)
            t = time.time()
            while time.time() - t < wait:
                self.pump(20)
                if self.their_ack == self.seq:
                    return
        raise Iap2Error(f'accessory did not ack link packet seq {self.seq}')

    def _wait(self, seconds, cond):
        t = time.time()
        while time.time() - t < seconds:
            self.pump(20)
            if cond():
                return True
        return cond()

    def _link(self, timeout):
        for _ in range(20):
            if not self._read(10):
                break
        t = time.time()
        while self.syn is None and time.time() - t < timeout:
            self._write(DETECT)                  # answer/prompt the accessory's detect
            self._wait(1.0, lambda: self.syn is not None)
        if self.syn is None:
            raise Iap2Error('accessory never sent an iAP2 link SYN')
        pl = self.syn['payload']
        sessions = [(pl[i], pl[i + 1]) for i in range(10, len(pl) - 2, 3)]
        self.session_ctrl = next((sid for sid, typ in sessions if typ == 0), None)
        self.session_ea = next((sid for sid, typ in sessions if typ == 2), None)
        if self.session_ctrl is None or self.session_ea is None:
            raise Iap2Error(f'accessory offered no control/EA session: {pl.hex()}')
        self.their_ack = None
        for _ in range(3):
            self._write(link_packet(SYN | ACK, self.seq, self.rack, 0, pl))
            if self._wait(1.5, lambda: self.their_ack == self.seq):
                break
        else:
            raise Iap2Error('accessory did not ack our SYN|ACK')
        self.linked = True

    # -- control session
    def send_control(self, msg_id, params=b''):
        if self.verbose:
            self.log(f'iap2 -> {MSG_NAMES.get(msg_id, hex(msg_id))}')
        self._send_data(self.session_ctrl, control_message(msg_id, params))

    def _on_control(self, payload):
        m = parse_control_message(payload)
        if not m:
            return
        msg_id, params = m
        if self.verbose:
            self.log(f'iap2 <- {MSG_NAMES.get(msg_id, hex(msg_id))}')
        if msg_id == MSG_IDENT_INFO:
            for pid, data in params:
                if pid == 10:
                    sub = dict(parse_parameters(data))
                    self.protocols.append((sub.get(0, b'\0')[0], _cstr(sub.get(1, b''))))
                elif pid in (0, 1, 2, 3, 4, 5, 11, 12, 13):
                    self.ident[IDENT_PARAMS[pid]] = _cstr(data)
                else:
                    self.ident[IDENT_PARAMS.get(pid, f'param{pid}')] = data.hex()
            self.ident['protocols'] = self.protocols
        elif msg_id == MSG_EA_STATUS:
            d = dict(params)
            self.ea_status = d.get(1, b'\xff')[0]

    # -- public api
    def open(self, protocol=None, ea_session_id=1, timeout=6.0):
        """Bring the link up, identify the accessory and open an EA session.

        protocol: EA protocol name (e.g. 'BOYA.DeviceLink.com'); None = the first
        one the accessory advertises."""
        self._link(timeout)
        self.send_control(MSG_START_IDENT)
        if not self._wait(3.0, lambda: 'name' in self.ident):
            raise Iap2Error('no IdentificationInformation from accessory')
        self.send_control(MSG_IDENT_ACCEPTED)
        self._wait(0.3, lambda: False)           # let PowerSourceUpdate & co. drain
        if not self.protocols:
            raise Iap2Error('accessory advertises no External Accessory protocol')
        pid = next((i for i, n in self.protocols if protocol in (None, n)), None)
        if pid is None:
            raise Iap2Error(f'accessory does not offer protocol {protocol!r}: {self.protocols}')
        self.ea_session_id = ea_session_id
        self.ea_status = None
        self.send_control(MSG_START_EA,
                          parameter(0, bytes([pid])) + parameter(1, struct.pack('>H', ea_session_id)))
        self._wait(1.0, lambda: self.ea_status is not None)
        if self.ea_status not in (None, 0):
            raise Iap2Error(f'accessory refused the EA session (status {self.ea_status})')
        return self.ident

    def send(self, data):
        """Write bytes into the EA session (blocks until the link ACK)."""
        self._send_data(self.session_ea, struct.pack('>H', self.ea_session_id) + bytes(data))

    def poll(self, seconds):
        """Pump the link for `seconds`; return the EA data chunks that arrived."""
        t = time.time()
        while time.time() - t < seconds:
            self.pump(20)
        out, self.ea_rx = self.ea_rx, []
        return out

    def close(self):
        if self.linked and self.ea_session_id is not None:
            try:
                self.send_control(MSG_STOP_EA, parameter(0, struct.pack('>H', self.ea_session_id)))
                self._wait(0.3, lambda: False)
            except Exception:
                pass
        self.linked = False


def claim(vid, pid, interface=1):
    """Find the device and claim its iAP interface (no kernel-driver detach needed)."""
    dev = usb.core.find(idVendor=vid, idProduct=pid)
    if dev is None:
        raise Iap2Error(f'USB device {vid:04x}:{pid:04x} not found')
    usb.util.claim_interface(dev, interface)
    return dev


if __name__ == '__main__':
    # smoke test: identify the BOYA mini 2 and list its EA protocols
    dev = claim(0x2F05, 0x003B)
    h = Iap2Host(dev, verbose='-v' in sys.argv)
    try:
        info = h.open()
        for k, v in info.items():
            print(f'{k:20} {v}')
    finally:
        h.close()
        usb.util.release_interface(dev, 1)
