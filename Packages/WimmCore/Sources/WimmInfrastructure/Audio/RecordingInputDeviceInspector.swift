import AVFoundation
import WimmDomain
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

public enum RecordingInputDeviceInspector {
    /// Read after starting capture. Never infer the mic from connected outputs
    /// or the system default: the engine can be bound to a different device.
    public static func current(inputNode: AVAudioInputNode? = nil) -> RecordingInputDevice? {
        guard let option = currentOption(inputNode: inputNode) else { return nil }
        return RecordingInputDevice(name: option.name, transport: option.transport)
    }

    public static func currentOption(inputNode: AVAudioInputNode? = nil) -> AudioInputOption? {
        #if os(macOS)
        guard let unit = inputNode?.audioUnit else { return nil }
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &device, &size) == noErr,
              device != kAudioObjectUnknown else { return nil }
        // CoreAudio may bind capture to a private aggregate
        // ("CADefaultDeviceAggregate-<pid>-<n>"), e.g. under voice processing.
        // Its name says nothing about the mic: report the input subdevice.
        if transportType(of: device) == kAudioDeviceTransportTypeAggregate,
           let input = inputSubdevice(of: device),
           let resolved = describeOption(input) {
            return resolved
        }
        return describeOption(device)
        #elseif os(iOS)
        guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        return AudioInputOption(uid: input.uid, name: input.portName, transport: input.portType.rawValue)
        #else
        return nil
        #endif
    }

    public static func availableInputDevices() -> [AudioInputOption] {
        #if os(macOS)
        return allDeviceIDs().compactMap { device in
            guard hasInputStreams(device), !isHidden(device),
                  let option = describeOption(device) else { return nil }
            if transportType(of: device) == kAudioDeviceTransportTypeAggregate,
               option.name.hasPrefix("CADefaultDeviceAggregate-") {
                return nil
            }
            return option
        }
        #else
        return []
        #endif
    }

    public static func systemDefaultInputUID() -> String? {
        #if os(macOS)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        if transportType(of: device) == kAudioDeviceTransportTypeAggregate,
           let input = inputSubdevice(of: device) {
            return deviceUID(of: input)
        }
        return deviceUID(of: device)
        #else
        return nil
        #endif
    }

    #if os(macOS)
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { hasInputStreams($0) && deviceUID(of: $0) == uid }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: kAudioObjectUnknown,
                                      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { $0 != kAudioObjectUnknown }
    }

    private static func describeOption(_ device: AudioObjectID) -> AudioInputOption? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameValue: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: nameValue))
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &nameValue) == noErr,
              let nameValue else { return nil }
        let name = nameValue.takeRetainedValue() as String
        guard !name.isEmpty, let uid = deviceUID(of: device) else { return nil }
        let kind: String
        switch transportType(of: device) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: kind = "builtIn"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "bluetooth"
        case kAudioDeviceTransportTypeUSB: kind = "usb"
        default: kind = "other"
        }
        return AudioInputOption(uid: uid, name: name, transport: kind)
    }

    private static func deviceUID(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidValue: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uidValue))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uidValue) == noErr,
              let uidValue else { return nil }
        let uid = uidValue.takeRetainedValue() as String
        return uid.isEmpty ? nil : uid
    }

    private static func isHidden(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &hidden) == noErr else {
            return false
        }
        return hidden != 0
    }

    private static func transportType(of device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport
    }

    /// The first active subdevice of an aggregate that has input streams.
    private static func inputSubdevice(of aggregate: AudioObjectID) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var subdevices = [AudioObjectID](repeating: kAudioObjectUnknown,
                                         count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &subdevices) == noErr else {
            return nil
        }
        return subdevices.first { $0 != kAudioObjectUnknown && hasInputStreams($0) }
    }

    private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
    #endif
}

#if os(macOS)
/// Watches CoreAudio for connected/disconnected audio devices and default input changes.
public final class AudioInputDeviceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var defaultBlock: AudioObjectPropertyListenerBlock?

    public init(onChange: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        var devicesAddress = Self.devicesAddress
        var defaultAddress = Self.defaultInputAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        if AudioObjectAddPropertyListenerBlock(system, &devicesAddress, DispatchQueue.main, block) == noErr {
            devicesBlock = block
        }
        if AudioObjectAddPropertyListenerBlock(system, &defaultAddress, DispatchQueue.main, block) == noErr {
            defaultBlock = block
        }
    }

    public func stop() {
        lock.lock()
        let devices = devicesBlock; devicesBlock = nil
        let def = defaultBlock; defaultBlock = nil
        lock.unlock()

        let system = AudioObjectID(kAudioObjectSystemObject)
        if let devices {
            var addr = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(system, &addr, DispatchQueue.main, devices)
        }
        if let def {
            var addr = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(system, &addr, DispatchQueue.main, def)
        }
    }

    deinit {
        stop()
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
#endif
