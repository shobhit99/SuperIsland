import Foundation
import CoreAudio
import AudioToolbox
import Combine
import AppKit

struct MediaAppVolume: Identifiable, Equatable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let iconName: String
    var volume: Float
    var isPlaying: Bool

    var statusText: String {
        isPlaying ? "Playing" : "Paused"
    }
}

@MainActor
final class VolumeManager: ObservableObject {
    static let shared = VolumeManager()

    @Published var volume: Float = 0
    @Published var isMuted: Bool = false
    @Published var outputDeviceName: String = "Unknown"
    @Published var mediaAppVolumes: [MediaAppVolume] = []

    private var defaultDeviceID: AudioDeviceID = 0
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var mediaPollTimer: Timer?
    private let appleScriptQueue = DispatchQueue(label: "com.workview.applescript", qos: .utility)

    private init() {
        setupDefaultDevice()
        updateVolume()
        updateMuteState()
        updateDeviceName()
        startMonitoring()
        startMediaMonitoring()
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

    private func startMediaMonitoring() {
        mediaPollTimer?.invalidate()
        mediaPollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refreshMediaAppVolumes()
        }
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
        let size = UInt32(MemoryLayout<Float32>.size)
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

    // MARK: - Media App Volume

    func refreshMediaAppVolumes() {
        appleScriptQueue.async { [weak self] in
            guard let self else { return }
            var apps: [MediaAppVolume] = []
            if let spotify = self.fetchMusicAppVolume(
                appID: "spotify",
                appName: "Spotify",
                bundleIdentifier: "com.spotify.client",
                processName: "Spotify",
                scriptAppName: "Spotify",
                iconName: "music.note.list"
            ) {
                apps.append(spotify)
            }
            if let music = self.fetchMusicAppVolume(
                appID: "apple-music",
                appName: "Apple Music",
                bundleIdentifier: "com.apple.Music",
                processName: "Music",
                scriptAppName: "Music",
                iconName: "music.note"
            ) {
                apps.append(music)
            }
            if let chrome = self.fetchChromeMediaVolume() {
                apps.append(chrome)
            }

            let sorted = apps.sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying {
                    return lhs.isPlaying && !rhs.isPlaying
                }
                return lhs.appName < rhs.appName
            }

            DispatchQueue.main.async { [weak self] in
                self?.mediaAppVolumes = sorted
            }
        }
    }

    func setMediaAppVolume(appID: String, volume: Float) {
        let clamped = max(0, min(1, volume))

        if let index = mediaAppVolumes.firstIndex(where: { $0.id == appID }) {
            mediaAppVolumes[index].volume = clamped
        }

        switch appID {
        case "spotify":
            setMusicAppVolume(processName: "Spotify", scriptAppName: "Spotify", volume: clamped)
        case "apple-music":
            setMusicAppVolume(processName: "Music", scriptAppName: "Music", volume: clamped)
        case "chrome":
            setChromeMediaVolume(clamped)
        default:
            break
        }
    }

    nonisolated private func fetchMusicAppVolume(
        appID: String,
        appName: String,
        bundleIdentifier: String,
        processName: String,
        scriptAppName: String,
        iconName: String
    ) -> MediaAppVolume? {
        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return "NOT_RUNNING"
        end tell
        tell application "\(scriptAppName)"
            set stateText to (player state as string)
            set vol to sound volume
            return (vol as string) & "||" & stateText
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING" else { return nil }
        let parts = result.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }

        let volumeValue = (Float(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 100.0
        let state = parts[1].lowercased()
        let isPlaying = state.contains("play")

        return MediaAppVolume(
            id: appID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            iconName: iconName,
            volume: max(0, min(1, volumeValue)),
            isPlaying: isPlaying
        )
    }

    private func setMusicAppVolume(processName: String, scriptAppName: String, volume: Float) {
        let target = Int((max(0, min(1, volume)) * 100).rounded())
        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return
        end tell
        tell application "\(scriptAppName)"
            set sound volume to \(target)
        end tell
        """
        appleScriptQueue.async { [weak self] in
            _ = self?.runAppleScript(script)
        }
    }

    nonisolated private func fetchChromeMediaVolume() -> MediaAppVolume? {
        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return "NOT_RUNNING"
        end tell
        tell application "Google Chrome"
            set foundMedia to false
            set maxVolume to 0
            set hasPlaying to false
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set mediaInfo to execute t javascript "(function(){var media=document.querySelectorAll('video,audio');if(!media.length){return 'NO_MEDIA';}var playing=false;var highest=0;for(var i=0;i<media.length;i++){var m=media[i];if(!m.paused&&!m.ended){playing=true;}var v=m.muted?0:m.volume;if(v>highest){highest=v;}}return (playing?'PLAYING':'PAUSED')+'||'+highest;})();"
                        if mediaInfo is not "NO_MEDIA" then
                            set foundMedia to true
                            set AppleScript's text item delimiters to "||"
                            set valuesList to text items of mediaInfo
                            if (count of valuesList) is greater than or equal to 2 then
                                set stateText to item 1 of valuesList
                                set volumeText to item 2 of valuesList
                                if stateText is "PLAYING" then set hasPlaying to true
                                set parsedVolume to (volumeText as real)
                                if parsedVolume > maxVolume then
                                    set maxVolume to parsedVolume
                                end if
                            end if
                            set AppleScript's text item delimiters to ""
                        end if
                    end try
                end repeat
            end repeat
            if not foundMedia then return "NO_MEDIA"
            set stateResult to "PAUSED"
            if hasPlaying then set stateResult to "PLAYING"
            return ((maxVolume * 100) as string) & "||" & stateResult
        end tell
        """

        guard let result = runAppleScript(script),
              result != "NOT_RUNNING",
              result != "NO_MEDIA"
        else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }

        let volumeValue = (Float(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 100.0
        let isPlaying = parts[1].uppercased().contains("PLAYING")

        return MediaAppVolume(
            id: "chrome",
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconName: "globe",
            volume: max(0, min(1, volumeValue)),
            isPlaying: isPlaying
        )
    }

    private func setChromeMediaVolume(_ volume: Float) {
        let normalized = String(format: "%.3f", max(0, min(1, volume)))
        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return
        end tell
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        execute t javascript "(function(){var media=document.querySelectorAll('video,audio');for(var i=0;i<media.length;i++){media[i].muted=false;media[i].volume=\(normalized);}})();"
                    end try
                end repeat
            end repeat
        end tell
        """
        appleScriptQueue.async { [weak self] in
            _ = self?.runAppleScript(script)
        }
    }

    nonisolated private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil {
            return nil
        }
        return result.stringValue
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

    deinit {
        mediaPollTimer?.invalidate()
    }
}
