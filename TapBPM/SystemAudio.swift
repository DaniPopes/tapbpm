#if os(macOS)
import AVFoundation
import CoreAudio

/// Everything the Mac plays, through a Core Audio tap on all processes. macOS asks for permission
/// on first use and delivers silence while it is denied.
final class SystemAudio: AudioInput {
    /// About ten callbacks a second instead of the default hundred.
    static let bufferFrames: UInt32 = 4096

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "TapBPM.SystemAudio", qos: .userInitiated)

    init(into window: AudioWindow) throws {
        do {
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            description.isPrivate = true
            try Self.check(AudioHardwareCreateProcessTap(description, &tap))
            // The tap needs an aggregate device to run, clocked by the current output device.
            let output = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "TapBPM",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString],
                ],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
            try Self.setProperty(kAudioDevicePropertyBufferFrameSize, of: device, to: Self.bufferFrames)
            var format = try Self.property(kAudioTapPropertyFormat, of: tap, as: AudioStreamBasicDescription.self)
            guard let input = AVAudioFormat(streamDescription: &format),
                  let resampler = Resampler(from: input, to: BeatTracker.sampleRate, into: window)
            else { throw AudioCapture.Unavailable() }
            try Self.check(Self.createIOProc(&proc, on: device, queue: queue, format: input, resampler: resampler))
            try Self.check(AudioDeviceStart(device, proc))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if device != kAudioObjectUnknown {
            AudioDeviceStop(device, proc)
            if let proc { AudioDeviceDestroyIOProcID(device, proc) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    }

    /// Nonisolated so the IO block, which runs on `queue`, is not main-actor isolated.
    nonisolated private static func createIOProc(
        _ proc: inout AudioDeviceIOProcID?,
        on device: AudioObjectID,
        queue: DispatchQueue,
        format: AVAudioFormat,
        resampler: Resampler
    ) -> OSStatus {
        AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, time, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input) else { return }
            resampler.append(buffer, at: AVAudioTime(hostTime: time.pointee.mHostTime))
        }
    }

    private static func defaultOutputUID() throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output = try property(kAudioHardwarePropertyDefaultOutputDevice, of: system, as: AudioObjectID.self)
        guard let uid = try property(kAudioDevicePropertyDeviceUID, of: output, as: Unmanaged<CFString>?.self) else {
            throw AudioCapture.Unavailable()
        }
        return uid.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, as _: T.Type) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value))
        return value.move()
    }

    private static func setProperty(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, to value: UInt32) throws {
        var address = address(selector)
        var value = value
        try check(AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioCapture.Unavailable() }
    }
}
#endif
