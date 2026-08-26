import Foundation

/// Every attribute id BOYA's "Mic2" family defines. A mini 2 implements 25 of
/// them (`Attr.miniTwo`); the rest are here so a stray id in a reply still gets
/// a name in the log. Names and ranges come from BOYA's own per-model metadata
/// and from `com.jiayz.device.BoYaMic2AttrId` in the Android app — see
/// `docs/PROTOCOL.md` §9.5.
enum Attr: UInt8, Sendable, CaseIterable {
    case tx1Battery = 1
    case tx1Charging = 2
    case tx1Mute = 3
    case tx1Signal = 4
    case tx1SerialNumber = 5
    case tx1Version = 6
    case tx1Wave = 7
    case tx1USB = 8
    case tx1Gain = 15
    case tx1MaxTime = 17
    case tx1RecordedTime = 18
    case tx1FormatFlag = 19
    case tx1Recording = 20
    case tx2Battery = 21
    case tx2Charging = 22
    case tx2Mute = 23
    case tx2Signal = 24
    case tx2SerialNumber = 25
    case tx2Version = 26
    case tx2Wave = 27
    case tx2USB = 28
    case tx2Gain = 35
    case tx2MaxTime = 37
    case tx2RecordedTime = 38
    case tx2FormatFlag = 39
    case tx2Recording = 40
    case sceneMode = 41
    case audioMode = 42
    case txLowCut = 43
    case txIndicatorLights = 44
    case txAutoPowerOff = 45
    // 46 (`agc`) is deliberately absent. BOYA's per-model metadata claims it
    // for the mini 2, but the receiver never answers for it: `get_all` omits it
    // and a direct read returns status 1 even with a transmitter online and
    // healthy. Leaving it out of the table means `HardwareTests.readsAttributes`
    // fails loudly if firmware ever starts reporting it.
    case noiseCancellation = 47
    case mute = 48
    case txAutoRecord = 58
    case txTouchLock = 59
    case txRecord32Bit = 60
    case rxBattery = 61
    case rxCharging = 62
    case tx1Online = 63
    case tx2Online = 64
    case rxGain = 65
    case rxOutputType = 66
    case rxAutoPowerOff = 67
    case recordingMode = 68
    case rxSpeaker = 69
    case rxPairEnable = 70
    case rxReset = 71
    case rxSerialNumber = 72
    case rxVersion = 73
    case rxCameraPresets = 74
    case rxSingleRecord = 75
    case rxBacklightTime = 76
    case rxScreenLight = 77
    case rxTimeSetting = 78
    case rxHeadphoneInput = 79
    case rxSingleLock = 80
    case rxLanguage = 81
    case rxUpdateState = 82

    /// The identifier used in logs and in `--probe` output — matches
    /// `boyactl.py`'s names so captures line up with the Python tool.
    var name: String {
        switch self {
        case .tx1Battery: "tx1_battery"
        case .tx1Charging: "tx1_charging"
        case .tx1Mute: "tx1_mute"
        case .tx1Signal: "tx1_signal"
        case .tx1SerialNumber: "tx1_sn"
        case .tx1Version: "tx1_version"
        case .tx1Wave: "tx1_wave"
        case .tx1USB: "tx1_usb"
        case .tx1Gain: "tx1_gain"
        case .tx1MaxTime: "tx1_max_time"
        case .tx1RecordedTime: "tx1_rec_time"
        case .tx1FormatFlag: "tx1_format_flag"
        case .tx1Recording: "tx1_recording"
        case .tx2Battery: "tx2_battery"
        case .tx2Charging: "tx2_charging"
        case .tx2Mute: "tx2_mute"
        case .tx2Signal: "tx2_signal"
        case .tx2SerialNumber: "tx2_sn"
        case .tx2Version: "tx2_version"
        case .tx2Wave: "tx2_wave"
        case .tx2USB: "tx2_usb"
        case .tx2Gain: "tx2_gain"
        case .tx2MaxTime: "tx2_max_time"
        case .tx2RecordedTime: "tx2_rec_time"
        case .tx2FormatFlag: "tx2_format_flag"
        case .tx2Recording: "tx2_recording"
        case .sceneMode: "scene_mode"
        case .audioMode: "audio_mode"
        case .txLowCut: "tx_low_cut"
        case .txIndicatorLights: "tx_indicator_lights"
        case .txAutoPowerOff: "tx_auto_poweroff"
        case .noiseCancellation: "nc"
        case .mute: "mute"
        case .txAutoRecord: "tx_auto_rec"
        case .txTouchLock: "tx_touch_lock"
        case .txRecord32Bit: "tx_rec_32bit"
        case .rxBattery: "rx_battery"
        case .rxCharging: "rx_charging"
        case .tx1Online: "tx1_online"
        case .tx2Online: "tx2_online"
        case .rxGain: "rx_gain"
        case .rxOutputType: "rx_output_type"
        case .rxAutoPowerOff: "rx_auto_poweroff"
        case .recordingMode: "recording_mode"
        case .rxSpeaker: "rx_speaker"
        case .rxPairEnable: "rx_pair_en"
        case .rxReset: "rx_reset"
        case .rxSerialNumber: "rx_sn"
        case .rxVersion: "rx_version"
        case .rxCameraPresets: "rx_camera_presets"
        case .rxSingleRecord: "rx_single_rec"
        case .rxBacklightTime: "rx_backlight_time"
        case .rxScreenLight: "rx_screen_light"
        case .rxTimeSetting: "rx_time_setting"
        case .rxHeadphoneInput: "rx_hp_input"
        case .rxSingleLock: "rx_single_lock"
        case .rxLanguage: "rx_language"
        case .rxUpdateState: "rx_update_state"
        }
    }

    /// What the popover and Settings call it.
    var title: String {
        switch self {
        case .noiseCancellation: "Noise Cancellation"
        case .rxGain: "Output Gain"
        case .sceneMode: "Scene Mode"
        case .recordingMode: "Recording Mode"
        case .mute: "Mute"
        case .txIndicatorLights: "Transmitter Indicator Lights"
        case .txAutoPowerOff: "Transmitter Auto Power Off"
        case .rxAutoPowerOff: "Receiver Auto Power Off"
        case .rxSpeaker: "Receiver Speaker Mode"
        case .rxPairEnable: "Pairing"
        case .rxReset: "Factory Reset"
        default: name
        }
    }

    /// Inclusive value range, where the device is known to enforce one.
    var range: ClosedRange<UInt8>? {
        switch self {
        case .tx1Battery, .tx1Signal, .tx2Battery, .tx2Signal, .rxBattery: 0...4
        case .tx1Charging, .tx2Charging, .rxCharging, .recordingMode: 0...2
        case .noiseCancellation: 0...2
        case .sceneMode: 0...4
        case .rxGain: 1...6
        case .tx1Mute, .tx1Wave, .tx2Mute, .tx2Wave, .tx1Online, .tx2Online,
             .txIndicatorLights, .txAutoPowerOff, .mute, .txAutoRecord,
             .txTouchLock, .txRecord32Bit, .rxAutoPowerOff, .rxSpeaker,
             .rxPairEnable, .rxSingleLock: 0...1
        default: nil
        }
    }

    /// Human labels for enumerated values.
    var labels: [UInt8: String]? {
        switch self {
        case .tx1Charging, .tx2Charging, .rxCharging:
            [0: "Not Charging", 1: "Charging", 2: "Fully Charged"]
        case .tx1Online, .tx2Online:
            // BOYA's own API says 0=Online — it is inverted. Verified by
            // toggling a transmitter; see docs/PROTOCOL.md §9.5.
            [0: "Offline", 1: "Online"]
        case .tx1Wave, .tx2Wave:
            [0: "Left Channel", 1: "Right Channel"]
        case .sceneMode:
            [0: "Original", 1: "Vocal Boost", 2: "Low Cut 75Hz", 3: "Low Cut 150Hz", 4: "Custom EQ"]
        case .noiseCancellation:
            [0: "Off", 1: "Weak (−15dB)", 2: "Strong (−40dB)"]
        case .recordingMode:
            [0: "Mono", 1: "Stereo", 2: "Safety Channel"]
        default:
            nil
        }
    }

    /// Writing these does more than change a setting, so they live behind a
    /// confirmation in Settings › Advanced and `ReceiverSession.setRisky`.
    var riskWarning: String? {
        switch self {
        case .rxSpeaker: "Changing speaker mode restarts the receiver."
        case .rxReset: "This resets the receiver to factory defaults."
        case .rxPairEnable: "This puts the receiver into pairing mode and can drop the current transmitters."
        default: nil
        }
    }

    var isRisky: Bool { riskWarning != nil }

    /// The 24 attributes a mini 2 actually answers for.
    static let miniTwo: Set<Attr> = [
        .tx1Battery, .tx1Charging, .tx1Signal, .tx1Wave,
        .tx2Battery, .tx2Charging, .tx2Signal, .tx2Wave,
        .sceneMode, .audioMode, .txIndicatorLights, .txAutoPowerOff,
        .noiseCancellation, .mute, .rxBattery, .rxCharging, .tx1Online,
        .tx2Online, .rxGain, .rxAutoPowerOff, .recordingMode, .rxSpeaker,
        .rxReset, .rxCameraPresets,
    ]

    /// Formats a value the way `boyactl.py` prints it — for logs and `--probe`.
    func describe(_ value: [UInt8]) -> String {
        guard value.count == 1 else { return value.map { String(format: "%02x", $0) }.joined() }
        let number = value[0]
        if let label = labels?[number] { return "\(number)  (\(label))" }
        return String(number)
    }
}

/// One decoded reply from the attribute layer: `[status, (id, len, value…)*]`.
///
/// A `get_all` returns only what is meaningful right now, so an attribute being
/// *absent* is how the device says "not available" — `agc` disappears when no
/// transmitter is connected, exactly as `status 1` does on a single read.
struct AttributeSnapshot: Sendable, Equatable {
    /// 0 = OK, 1 = the attribute is not available right now.
    var status: UInt8
    /// Attribute id → raw value bytes, unknown ids included.
    var values: [UInt8: [UInt8]]

    init(status: UInt8 = 0, values: [UInt8: [UInt8]] = [:]) {
        self.status = status
        self.values = values
    }

    init(decoding payload: [UInt8]) {
        status = payload.first ?? 0
        values = [:]
        var index = 1
        while index + 1 < payload.count {
            let id = payload[index]
            let length = Int(payload[index + 1])
            let start = index + 2
            guard length > 0, start + length <= payload.count else { break }
            values[id] = Array(payload[start..<(start + length)])
            index = start + length
        }
    }

    var isAvailable: Bool { status == 0 }

    subscript(attr: Attr) -> [UInt8]? { values[attr.rawValue] }

    /// Single-byte value of an attribute, or nil when the device did not report it.
    func byte(_ attr: Attr) -> UInt8? {
        guard let value = values[attr.rawValue], value.count == 1 else { return nil }
        return value
            .first
    }

    func flag(_ attr: Attr) -> Bool? {
        guard let value = byte(attr) else { return nil }
        return value != 0
    }

    /// Merges a newer reply over this one. Used for single-attribute read-backs,
    /// which must not blank out everything else the poll knows.
    func merging(_ other: AttributeSnapshot) -> AttributeSnapshot {
        AttributeSnapshot(status: other.status, values: values.merging(other.values) { _, new in new })
    }

    /// Ordered for display: known mini 2 attributes by id, then anything else.
    var sortedEntries: [(id: UInt8, attr: Attr?, value: [UInt8])] {
        values.keys.sorted().map { (id: $0, attr: Attr(rawValue: $0), value: values[$0] ?? []) }
    }
}

/// What the popover shows for one transmitter. `online` is the only trustworthy
/// connection flag: when a TX is docked the receiver leaves battery and signal
/// at their last-known values rather than zeroing them.
struct TransmitterState: Sendable, Equatable {
    var index: Int
    var isOnline: Bool
    var battery: UInt8?
    var signal: UInt8?
    var charging: UInt8?
    var channel: UInt8?

    /// Battery level to show, or nil when nothing live is known.
    var liveBattery: UInt8? { isOnline ? battery : nil }
}

struct ReceiverState: Sendable, Equatable {
    var battery: UInt8?
    var charging: UInt8?
}

extension AttributeSnapshot {
    func transmitter(_ index: Int) -> TransmitterState {
        let first = index == 1
        return TransmitterState(
            index: index,
            isOnline: flag(first ? .tx1Online : .tx2Online) ?? false,
            battery: byte(first ? .tx1Battery : .tx2Battery),
            signal: byte(first ? .tx1Signal : .tx2Signal),
            charging: byte(first ? .tx1Charging : .tx2Charging),
            channel: byte(first ? .tx1Wave : .tx2Wave)
        )
    }

    var tx1: TransmitterState { transmitter(1) }
    var tx2: TransmitterState { transmitter(2) }
    var receiver: ReceiverState { ReceiverState(battery: byte(.rxBattery), charging: byte(.rxCharging)) }
}
