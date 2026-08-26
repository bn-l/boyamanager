// eaprobe - does macOS's ExternalAccessory stack see the BOYA mini 2?
//
//   eaprobe list                 enumerate connected accessories + protocol strings
//   eaprobe session [seconds]    open EASession on BOYA.DeviceLink.com, send CFD
//                                heartbeats, hex-dump everything that comes back
import Foundation
import ExternalAccessory

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

// ---- CFD-Link frame builder (same as boyactl.py) ------------------------------
func cfd(msg: UInt16, payload: [UInt8] = [], chid: UInt8 = 0, vid: UInt8 = 0,
         pid: UInt16 = 0, seq: UInt16, src: UInt8 = 2, dst: UInt8 = 1,
         svc: UInt16 = 0x1D, flags: UInt8 = 0) -> Data {
    var b: [UInt8] = [0x55, 0x10 | flags]
    let len = UInt16(payload.count)
    b += [UInt8(len & 0xff), UInt8(len >> 8)]
    b += [UInt8(seq & 0xff), UInt8(seq >> 8)]
    b += [src, dst]
    b += [UInt8(svc & 0xff), UInt8(svc >> 8)]
    b += [chid, vid, UInt8(pid & 0xff), UInt8(pid >> 8)]
    b += [UInt8(msg & 0xff), UInt8(msg >> 8)]
    b += payload
    let sum = b.reduce(0) { ($0 + UInt32($1)) & 0xff }
    b.append(UInt8(sum))
    return Data(b)
}

let t0 = Date()
func hbPayload() -> [UInt8] {
    let tick = UInt32(Date().timeIntervalSince(t0) * 1000)
    return [0x00, 0x00, 0x04, 0x00, 0x01, 0x09,
            UInt8(tick & 0xff), UInt8((tick >> 8) & 0xff), UInt8((tick >> 16) & 0xff), UInt8(tick >> 24),
            0, 0, 0x24]
}

// ---- Stream plumbing --------------------------------------------------------------
final class Pump: NSObject, StreamDelegate {
    var input: InputStream
    var output: OutputStream
    var seq: UInt16 = 1
    var rxbuf = Data()
    var pending: [Data] = []
    var canWrite = false

    init(_ i: InputStream, _ o: OutputStream) { input = i; output = o }

    func next() -> UInt16 { seq &+= 1; return seq }

    func send(_ d: Data) {
        pending.append(d)
        flush()
    }

    func flush() {
        guard canWrite || output.hasSpaceAvailable else { return }
        while let d = pending.first {
            let n = d.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count) }
            if n <= 0 { print("write returned \(n) err=\(String(describing: output.streamError))"); return }
            print("TX \(hex(d))")
            pending.removeFirst()
            canWrite = false
        }
    }

    func stream(_ s: Stream, handle e: Stream.Event) {
        switch e {
        case .openCompleted:
            print("\(s === input ? "in" : "out") open")
        case .hasSpaceAvailable:
            canWrite = true; flush()
        case .hasBytesAvailable:
            var buf = [UInt8](repeating: 0, count: 1024)
            while input.hasBytesAvailable {
                let n = input.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                print("RX \(hex(chunk))")
                rxbuf.append(chunk)
                parse()
            }
        case .errorOccurred:
            print("stream error \(String(describing: s.streamError))")
        case .endEncountered:
            print("stream end")
        default: break
        }
    }

    // byte-stream reassembly like cfdl_io_in
    func parse() {
        while true {
            while rxbuf.count >= 2 && !(rxbuf[rxbuf.startIndex] == 0x55 && (rxbuf[rxbuf.startIndex + 1] & 0xF0) == 0x10) {
                rxbuf.removeFirst()
            }
            guard rxbuf.count >= 17 else { return }
            let s = rxbuf.startIndex
            let len = Int(rxbuf[s + 2]) | (Int(rxbuf[s + 3]) << 8)
            if len > 0x480 { rxbuf.removeFirst(); continue }
            let total = 17 + len
            guard rxbuf.count >= total else { return }
            let f = rxbuf.subdata(in: s..<(s + total))
            rxbuf.removeFirst(total)
            let ok = f.dropLast().reduce(0) { ($0 + UInt32($1)) & 0xff } == UInt32(f.last!)
            handle(f, ok: ok)
        }
    }

    func handle(_ f: Data, ok: Bool) {
        let b = [UInt8](f)
        let msg = UInt16(b[14]) | (UInt16(b[15]) << 8)
        let svc = UInt16(b[8]) | (UInt16(b[9]) << 8)
        let pid = UInt16(b[12]) | (UInt16(b[13]) << 8)
        let payload = Array(b[16..<(b.count - 1)])
        print(String(format: "FRAME ok=%d src=%d dst=%d svc=0x%02X chid=%d vid=%d pid=%d msg=0x%02X payload=%@",
                     ok ? 1 : 0, b[6], b[7], svc, b[10], b[11], pid, msg, hex(Data(payload))))
        if msg == 0 && (svc == 0x1D || svc == 0x1E) {
            // reply to the heartbeat, addressed to the sender's node handle
            send(cfd(msg: 0, payload: hbPayload(), chid: b[10], vid: b[11], pid: pid,
                     seq: next(), src: b[7], dst: b[6], svc: svc))
        }
    }
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "list"
let mgr = EAAccessoryManager.shared()

print("connected accessories: \(mgr.connectedAccessories.count)")
for a in mgr.connectedAccessories {
    print("  [\(a.connectionID)] name=\(a.name) manufacturer=\(a.manufacturer) model=\(a.modelNumber) sn=\(a.serialNumber) fw=\(a.firmwareRevision) hw=\(a.hardwareRevision) connected=\(a.isConnected)")
    print("     protocols: \(a.protocolStrings)")
}

if mode == "session" {
    let secs = args.count > 2 ? Double(args[2]) ?? 6 : 6
    guard let acc = mgr.connectedAccessories.first(where: { $0.protocolStrings.contains("BOYA.DeviceLink.com") }) else {
        print("no accessory advertising BOYA.DeviceLink.com"); exit(1)
    }
    guard let sess = EASession(accessory: acc, forProtocol: "BOYA.DeviceLink.com"),
          let i = sess.inputStream, let o = sess.outputStream else {
        print("EASession failed"); exit(1)
    }
    let pump = Pump(i, o)
    i.delegate = pump; o.delegate = pump
    i.schedule(in: .main, forMode: .default); o.schedule(in: .main, forMode: .default)
    i.open(); o.open()

    // broadcast heartbeat every 500 ms, like boyactl.py
    var beats = 0
    let hb = Timer(timeInterval: 0.5, repeats: true) { _ in
        pump.send(cfd(msg: 0, payload: hbPayload(), seq: pump.next()))
        beats += 1
        // after the link is up, ask the settings node (1,2,29) to describe itself, then read attr 47 (nc)
        if beats == 4 { pump.send(cfd(msg: 0x15, chid: 1, vid: 2, pid: 29, seq: pump.next())) }
        if beats == 6 { pump.send(cfd(msg: 0x1F, payload: [47], chid: 1, vid: 2, pid: 29, seq: pump.next())) }
        if beats == 8 { pump.send(cfd(msg: 0x21, payload: [0], chid: 1, vid: 2, pid: 29, seq: pump.next())) }
    }
    RunLoop.main.add(hb, forMode: .default)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: secs))
    i.close(); o.close()
    print("done")
}
