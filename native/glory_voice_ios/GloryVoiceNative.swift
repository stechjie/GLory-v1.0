import AVFoundation
import Foundation
import LiveKit

// All public calls are marshalled onto the main queue by the Godot bridge.
// Room delegate callbacks may arrive on WebRTC threads; marshal those too.
@objc(GloryVoiceNative)
@MainActor
public final class GloryVoiceNative: NSObject, RoomDelegate {
    @objc public static let shared = GloryVoiceNative()
    private var activeRoom: Room?
    private var generation = 0
    private var desiredMic = false
    private var microphoneTask: Task<Void, Never>?
    private var micError = ""
    private var connectionError = ""
    private var permissionPending = false
    private var volumes: [String: Double] = [:]

    @objc public func hasRecordPermission() -> Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    @objc public func requestRecordPermission() {
        guard !permissionPending else { return }
        permissionPending = true
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] _ in
            Task { @MainActor in self?.permissionPending = false }
        }
    }

    @objc public func joinRoom(_ url: String, token: String, listenOnly: Bool) -> String {
        guard let endpoint = URL(string: url), endpoint.scheme == "wss", endpoint.host != nil,
              !token.isEmpty else { return "invalid_config" }
        leaveRoom()
        let serial = generation
        desiredMic = !listenOnly
        micError = ""
        connectionError = ""
        // The SDK configures playAndRecord/voiceChat for capture and performs
        // echo cancellation. Keep game audio mixing and route selection native.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        AudioManager.shared.audioSession.isSpeakerOutputPreferred = true
        let room = Room(delegate: self)
        activeRoom = room
        Task { @MainActor [weak self] in
            do {
                try await room.connect(url: url, token: token)
                guard let self, self.generation == serial, self.activeRoom === room else {
                    await room.disconnect()
                    return
                }
                self.applyVolumes(room)
                self.reconcileMicrophone(room, serial: serial)
            } catch {
                guard let self, self.generation == serial, self.activeRoom === room else { return }
                self.connectionError = "connect_failed"
            }
        }
        return ""
    }

    @objc public func leaveRoom() {
        generation += 1
        desiredMic = false
        microphoneTask?.cancel()
        microphoneTask = nil
        let previous = activeRoom
        activeRoom = nil
        micError = ""
        connectionError = ""
        if let previous {
            Task { await previous.disconnect() }
        }
    }

    @objc public func setMicrophoneEnabled(_ enabled: Bool) -> String {
        if enabled && !hasRecordPermission() { return "no_permission" }
        desiredMic = enabled
        micError = ""
        if let room = activeRoom, room.connectionState == .connected {
            reconcileMicrophone(room, serial: generation)
        }
        return ""
    }

    // Serialize toggles. A late publish completion may not re-enable the mic
    // after switching to Listen, leaving a room, or joining a different team.
    private func reconcileMicrophone(_ room: Room, serial: Int) {
        guard microphoneTask == nil else { return }
        microphoneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == serial { self.microphoneTask = nil } }
            while !Task.isCancelled && self.generation == serial && self.activeRoom === room {
                let wanted = self.desiredMic
                do {
                    if wanted && !self.hasRecordPermission() {
                        self.micError = "no_permission"
                        return
                    }
                    try await room.localParticipant.setMicrophone(enabled: wanted)
                } catch {
                    if self.generation == serial { self.micError = "mic_failed" }
                    return
                }
                guard self.generation == serial, self.activeRoom === room else {
                    await room.disconnect()
                    return
                }
                if self.desiredMic == wanted { return }
            }
        }
    }

    @objc public func setParticipantVolume(_ identity: String, volume: Double) {
        volumes[identity] = min(1, max(0, volume))
        if let room = activeRoom { applyVolumes(room) }
    }

    private func applyVolumes(_ room: Room) {
        for participant in room.remoteParticipants.values {
            let identity = participant.identity?.stringValue ?? ""
            for publication in participant.trackPublications.values {
                if let audio = publication.track as? RemoteAudioTrack {
                    audio.volume = volumes[identity] ?? 1
                }
            }
        }
    }

    @objc public func getStatus() -> String {
        let room = activeRoom
        var state = "disconnected"
        if let room {
            switch room.connectionState {
            case .connected: state = "connected"
            case .connecting: state = "connecting"
            case .reconnecting: state = "reconnecting"
            case .disconnected: state = connectionError.isEmpty ? "connecting" : "failed"
            @unknown default: state = "failed"
            }
        }
        if !connectionError.isEmpty { state = "failed" }
        let participants = room?.remoteParticipants.values.map { $0.identity?.stringValue ?? "" }.sorted() ?? []
        let speaking = room?.remoteParticipants.values.filter { $0.isSpeaking }.map { $0.identity?.stringValue ?? "" }.sorted() ?? []
        let session = AVAudioSession.sharedInstance()
        let permission: String
        switch session.recordPermission {
        case .granted: permission = "granted"
        case .denied: permission = "denied"
        default: permission = permissionPending ? "prompting" : "undetermined"
        }
        return json([
            "state": state, "error": connectionError,
            "mic_on": room?.localParticipant.isMicrophoneEnabled() ?? false,
            "mic_error": micError, "permission": permission,
            "self_speaking": room?.localParticipant.isSpeaking ?? false,
            "speaking": speaking, "participants": participants,
            "audio_mode": session.category.rawValue,
            "output": session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        ])
    }

    @objc public func getCapabilities() -> String {
        json(["platform":"ios", "sdk":"livekit-swift-2.17.0", "aec":"webrtc",
              "listen_mode_fixed_at_join":false, "native_record_permission":true])
    }

    private func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    nonisolated public func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.activeRoom === room else { return }
            self.connectionError = "disconnected"
        }
    }

    nonisolated public func room(_ room: Room, participant: RemoteParticipant,
                                didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in
            guard let self, self.activeRoom === room else { return }
            self.applyVolumes(room)
        }
    }
}
