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
           let resolved = describe(input) {
            return resolved
        }
        return describe(device)
        #elseif os(iOS)
        guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        return RecordingInputDevice(name: input.portName, transport: input.portType.rawValue)
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func describe(_ device: AudioObjectID) -> RecordingInputDevice? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameValue: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: nameValue))
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &nameValue) == noErr,
              let nameValue else { return nil }
        let name = nameValue.takeRetainedValue() as String
        guard !name.isEmpty else { return nil }
        let kind: String
        switch transportType(of: device) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: kind = "builtIn"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "bluetooth"
        case kAudioDeviceTransportTypeUSB: kind = "usb"
        default: kind = "other"
        }
        return RecordingInputDevice(name: name, transport: kind)
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
