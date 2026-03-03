import Foundation
import CoreAudio
import AudioToolbox
import Combine

final class VolumeManager: ObservableObject {
    static let shared = VolumeManager()

    @Published var volume: Float = 0
    @Published var isMuted: Bool = false
    @Published var outputDeviceName: String = "Unknown"

    private var defaultDeviceID: AudioDeviceID = 0
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        setupDefaultDevice()
        updateVolume()
        updateMuteState()
        updateDeviceName()
        startMonitoring()
    }

    // MARK: - Setup

    private func setupDefaultDevice() {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )

        if status == noErr {
            defaultDeviceID = deviceID
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Listen for volume changes
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateVolume()
                AppState.shared.showHUD(module: .volumeHUD)
            }
        }
        volumeListenerBlock = volumeBlock

        AudioObjectAddPropertyListenerBlock(
            defaultDeviceID, &volumeAddress,
            DispatchQueue.main, volumeBlock
        )

        // Listen for mute changes
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateMuteState()
                AppState.shared.showHUD(module: .volumeHUD)
            }
        }
        muteListenerBlock = muteBlock

        AudioObjectAddPropertyListenerBlock(
            defaultDeviceID, &muteAddress,
            DispatchQueue.main, muteBlock
        )

        // Listen for default device changes
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.setupDefaultDevice()
                self?.updateVolume()
                self?.updateMuteState()
                self?.updateDeviceName()
            }
        }
        deviceListenerBlock = deviceBlock

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            DispatchQueue.main, deviceBlock
        )
    }

    // MARK: - State Updates

    private func updateVolume() {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            defaultDeviceID, &address, 0, nil, &size, &vol
        )

        if status == noErr {
            volume = vol
        }
    }

    private func updateMuteState() {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            defaultDeviceID, &address, 0, nil, &size, &muted
        )

        if status == noErr {
            isMuted = muted != 0
        }
    }

    private func updateDeviceName() {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            defaultDeviceID, &address, 0, nil, &size, &name
        )

        if status == noErr {
            outputDeviceName = name as String
        }
    }

    // MARK: - Volume Control

    func setVolume(_ newVolume: Float) {
        var vol = max(0, min(1, newVolume))
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(
            defaultDeviceID, &address, 0, nil, size, &vol
        )
    }

    func toggleMute() {
        var muted: UInt32 = isMuted ? 0 : 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(
            defaultDeviceID, &address, 0, nil, size, &muted
        )
    }

    // MARK: - Helpers

    var volumeIconName: String {
        if isMuted || volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var volumePercentage: Int {
        Int(volume * 100)
    }
}
