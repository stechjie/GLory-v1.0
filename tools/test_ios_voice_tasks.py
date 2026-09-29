"""Run production iOS Swift task logic against deterministic SDK doubles on macOS.
No microphone, Apple credentials, network or audio device is used.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STUBS = r'''
import Foundation
public protocol RoomDelegate {}
public struct LiveKitError: Error {}
struct Identifier { var stringValue: String }
struct ParticipantTrackPermission {
    init(participantSid: String, allTracksAllowed: Bool, allowedTrackSids: [String]) {}
}
struct ConnectOptions { var autoSubscribe: Bool }
class RemoteAudioTrack { var volume: Double = 1 }
public class RemoteTrackPublication { var track: Any? }
public class RemoteParticipant {
    var identity: Identifier?; var sid: Identifier?; var isSpeaking = false
    var trackPublications: [String: RemoteTrackPublication] = [:]
}
class AVAudioSession {
    enum Permission { case granted, denied, undetermined }
    static let shared = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared }
    var active = false
    var categoryChanges = 0
    enum Option: Hashable { case defaultToSpeaker, allowBluetooth, mixWithOthers }
    func setCategory(_ category: Identifier, mode: Identifier, options: Set<Option>) throws {
        self.category = category; self.mode = mode; categoryChanges += 1
    }
    func setActive(_ active: Bool) throws { self.active = active }
    var recordPermission = Permission.granted
    func requestRecordPermission(_ reply: @escaping (Bool) -> Void) { reply(true) }
    var category = Identifier(stringValue: "playAndRecord")
    var mode = Identifier(stringValue: "default")
    struct Route { var outputs: [Port] = [] }
    struct Port { var portType: Identifier }
    var currentRoute = Route()
}
extension Identifier {
    var rawValue: String { stringValue }
    static let playAndRecord = Identifier(stringValue: "playAndRecord")
    static let `default` = Identifier(stringValue: "default")
}
struct AudioEngineAvailability {
    var enabled: Bool
    static let none = AudioEngineAvailability(enabled: false)
    static let `default` = AudioEngineAvailability(enabled: true)
}
class AudioManager {
    static let shared = AudioManager()
    class Session {
        var isAutomaticConfigurationEnabled = true
        var isAutomaticDeactivationEnabled = true
        var isSpeakerOutputPreferred = true
    }
    var available = true
    func setEngineAvailability(_ availability: AudioEngineAvailability) throws { available = availability.enabled }
    var audioSession = Session()
    var isPlatformVoiceProcessingAllowed = true
    func setPlatformVoiceProcessingAllowed(_ allowed: Bool) throws { isPlatformVoiceProcessingAllowed = allowed }
}
@MainActor class LocalParticipant {
    var mic = false; var isSpeaking = false
    var muteCalls = 0; var failNextEnable = false
    var suspendNextEnable = false; var enableStarted = false
    var suspendPermission = false; var permissionStarted = false
    var permissionGate: CheckedContinuation<Void, Never>?
    func isMicrophoneEnabled() -> Bool { mic }
    func setMicrophone(enabled: Bool) async throws {
        if !enabled { muteCalls += 1 }
        if enabled && failNextEnable { failNextEnable = false; throw LiveKitError() }
        if enabled && suspendNextEnable {
            suspendNextEnable = false; enableStarted = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        mic = enabled
    }
    func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool, trackPermissions: [ParticipantTrackPermission]) async throws {
        if suspendPermission {
            suspendPermission = false; permissionStarted = true
            await withCheckedContinuation { permissionGate = $0 }
        }
    }
}
@MainActor public class Room {
    enum State { case connected, connecting, reconnecting, disconnected }
    static var created: [Room] = []
    var connectionState = State.disconnected
    var localParticipant = LocalParticipant()
    var remoteParticipants: [String: RemoteParticipant] = [:]
    var disconnects = 0
    init(delegate: RoomDelegate) { Self.created.append(self) }
    func connect(url: String, token: String, connectOptions: ConnectOptions) async throws { connectionState = .connected }
    func disconnect() async { disconnects += 1; connectionState = .disconnected; localParticipant.mic = false }
}
'''
TESTS = r'''
@main struct Tests {
    @MainActor static func spin(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        fatalError("Timed out waiting for test state")
    }
    @MainActor static func status(_ voice: GloryVoiceNative) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(voice.getStatus().utf8)) as! [String: Any]
    }
    @MainActor static func main() async {
        let voice = GloryVoiceNative.shared
        _ = voice.joinRoom("wss://example.test", token: "test", listenOnly: true)
        let first = Room.created.last!
        await spin { first.connectionState == .connected }
        for _ in 0..<30 { _ = voice.getStatus(); await Task.yield() }
        first.localParticipant.suspendNextEnable = true
        _ = voice.setMicrophoneEnabled(true)
        await spin { first.localParticipant.enableStarted }
        voice.setAudience(true, identitiesJson: "[]")
        await spin { first.localParticipant.mic }
        assert(status(voice)["mic_error"] as? String == "", "Intentional cancellation must not report mic_failed")
        print("PASS audience change cancels old publish without false mic failure")

        let muteCalls = first.localParticipant.muteCalls
        voice.setAudience(true, identitiesJson: "[]")
        for _ in 0..<30 { _ = voice.getStatus(); await Task.yield() }
        assert(first.localParticipant.muteCalls == muteCalls, "Repeated audience must not interrupt capture")
        assert(!AudioManager.shared.audioSession.isAutomaticConfigurationEnabled)
        assert(AVAudioSession.shared.active)
        print("PASS stable duplex session and idempotent audience")

        first.localParticipant.suspendPermission = true
        voice.setAudience(false, identitiesJson: "[]")
        await spin { first.localParticipant.permissionStarted }
        voice.leaveRoom()
        _ = voice.joinRoom("wss://example.test", token: "next", listenOnly: true)
        let second = Room.created.last!
        for _ in 0..<50 { await Task.yield() }
        assert(second.connectionState != .connected, "New room must wait for prior audience SDK task")
        first.localParticipant.permissionGate?.resume()
        await spin { second.connectionState == .connected }
        assert(first.disconnects > 0)
        assert(status(voice)["mic_error"] as? String == "")
        assert(!second.localParticipant.mic, "Listen-only replacement must not publish")
        print("PASS replacement waits for old audience task and remains listen-only")
        voice.setApplicationActive(false)
        voice.leaveRoom()
        assert(!AudioManager.shared.available, "Background must block capture and playback")
        assert(voice.joinRoom("wss://example.test", token: "background", listenOnly: false) == "paused")
        AVAudioSession.shared.active = false
        voice.setApplicationActive(true)
        await spin { AudioManager.shared.available && AVAudioSession.shared.active }
        assert(second.disconnects > 0, "Resume must wait for previous room cleanup")
        _ = voice.joinRoom("wss://example.test", token: "foreground", listenOnly: true)
        let third = Room.created.last!
        await spin { third.connectionState == .connected }
        for _ in 0..<30 { _ = voice.getStatus(); await Task.yield() }
        assert(!third.localParticipant.mic, "Foreground may not promote Listen to Talk")
        third.localParticipant.failNextEnable = true
        _ = voice.setMicrophoneEnabled(true)
        await spin { status(voice)["state"] as? String == "failed" }
        assert(status(voice)["error"] as? String == "audio_device_failed")
        assert(status(voice)["mic_error"] as? String == "")
        print("PASS foreground restores audio after cleanup; transient device failure requests reconnect")
        voice.leaveRoom()
    }
}
'''

class IOSTaskTests(unittest.TestCase):
    def test_production_task_lifecycle(self):
        source = (ROOT / 'native/glory_voice_ios/GloryVoiceNative.swift').read_text()
        source = source.replace('import AVFoundation', '').replace('import LiveKit', '')
        source = source.replace('@objc(GloryVoiceNative)', '').replace('@objc ', '')
        with tempfile.TemporaryDirectory(prefix='glory-ios-task-tests-') as directory:
            swift = pathlib.Path(directory) / 'TaskTests.swift'
            binary = pathlib.Path(directory) / 'tests'
            swift.write_text(STUBS + source + TESTS)
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', str(swift), '-o', str(binary)], check=True, timeout=120)
            subprocess.run([str(binary)], check=True, timeout=20)

if __name__ == '__main__':
    unittest.main()
