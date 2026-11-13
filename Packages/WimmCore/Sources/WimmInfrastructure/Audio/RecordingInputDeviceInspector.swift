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
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameValue: Unmanaged<CFString>?
        size = UInt32(MemoryLayout.size(ofValue: nameValue))
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &nameValue) == noErr,
              let nameValue else { return nil }
        let name = nameValue.takeRetainedValue() as String
        guard !name.isEmpty else { return nil }
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport)
        let kind: String
        switch status == noErr ? transport : 0 {
        case kAudioDeviceTransportTypeBuiltIn: kind = "builtIn"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "bluetooth"
        case kAudioDeviceTransportTypeUSB: kind = "usb"
        default: kind = "other"
        }
        return RecordingInputDevice(name: name, transport: kind)
        #elseif os(iOS)
        guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        return RecordingInputDevice(name: input.portName, transport: input.portType.rawValue)
        #else
        return nil
        #endif
    }
}
