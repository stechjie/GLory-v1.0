import AVFoundation
import Foundation
import LiveKit

// All public calls are marshalled onto the main queue by the Godot bridge.
// Room delegate callbacks may arrive on WebRTC threads; marshal those too.
@objc(GloryVoiceNative)
@MainActor
public final class GloryVoiceNative: NSObject, RoomDelegate {
    @objc public static let shared = GloryVoiceNative()
    private var applicationActive = true
    private var audioConfigured = false
    private var audioResumeRevision = 0
    private var audioResumeTask: Task<Void, Never>?
    private var audioSessionError = ""
    private var activeRoom: Room?
    private var generation = 0
    private var desiredMic = false
    private var audienceAll = false
    private var audienceIds: Set<String> = []
    private var audienceReady = false
    private var audienceRevision = 0
    private var audienceFingerprint = ""
    private var audienceTask: Task<Void, Never>?
    private var microphoneTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var micError = ""
    private var connectionError = ""
    private var permissionPending = false
    private var volumes: [String: Double] = [:]

    // The game and WebRTC use separate engines but one AVAudioSession. Keep
    // a stable duplex category; capture is still controlled only by the mic.
    private func activateAudioSession() throws {
        let audio = AudioManager.shared
        audio.audioSession.isAutomaticConfigurationEnabled = false
        audio.audioSession.isAutomaticDeactivationEnabled = false
        if audioConfigured {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        }
        try AVAudioSession.sharedInstance().setActive(true)
        audioSessionError = ""
    }

    @objc public func setApplicationActive(_ active: Bool) {
        applicationActive = active
        audioResumeRevision += 1
        let revision = audioResumeRevision
        audioResumeTask?.cancel()
        if !active {
            // Prevent in-flight publication/subscription work restarting capture
            // while Godot is still delivering the background notification.
            do { try AudioManager.shared.setEngineAvailability(.none) }
            catch { audioSessionError = "audio_suspend_failed" }
            return
        }
        let pendingDisconnect = disconnectTask
        audioResumeTask = Task { @MainActor [weak self] in
            await pendingDisconnect?.value
            guard let self, !Task.isCancelled, self.applicationActive,
                  self.audioResumeRevision == revision else { return }
            do {
                try self.activateAudioSession()
                try AudioManager.shared.setEngineAvailability(.default)
            } catch { self.audioSessionError = "audio_resume_failed" }
        }
    }

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
        guard applicationActive else { return "paused" }
        leaveRoom()
        let serial = generation
        desiredMic = !listenOnly
        micError = ""
        connectionError = ""
        let previousDisconnect = disconnectTask
        let room = Room(delegate: self)
        activeRoom = room
        connectionTask = Task { @MainActor [weak self] in
            await previousDisconnect?.value
            guard let self, self.generation == serial, self.activeRoom === room, self.applicationActive else { return }
            // Godot and LiveKit share the process-wide audio session. A previous
            // room must finish tearing down before the next one starts using it.
            do {
                let audio = AudioManager.shared
                self.audioConfigured = true
                try self.activateAudioSession()
                try audio.setEngineAvailability(.default)
                audio.audioSession.isAutomaticConfigurationEnabled = false
                audio.audioSession.isAutomaticDeactivationEnabled = false
                audio.audioSession.isSpeakerOutputPreferred = true
                // Use WebRTC software AEC/NS/AGC, not Apple's Voice Processing
                // I/O. VPIO changes the output path and ducks Godot's separate
                // CoreAudio player. Music gain is controlled in MusicService.
                try audio.setPlatformVoiceProcessingAllowed(false)
            } catch {
                self.connectionError = "audio_device_failed"
                return
            }
            do {
                try await room.connect(url: url, token: token,
                                       connectOptions: ConnectOptions(autoSubscribe: true))
                guard self.generation == serial, self.activeRoom === room else {
                    await room.disconnect()
                    return
                }
                self.applyVolumes(room)
                self.updateAudience(room, serial: serial)
            } catch {
                guard self.generation == serial, self.activeRoom === room else { return }
                self.connectionError = "connect_failed"
            }
        }
        return ""
    }

    @objc public func leaveRoom() {
        generation += 1
        desiredMic = false
        audienceReady = false
        audienceRevision += 1
        audienceFingerprint = ""
        let previousAudience = audienceTask
        previousAudience?.cancel()
        audienceTask = nil
        let previousMicrophone = microphoneTask
        previousMicrophone?.cancel()
        microphoneTask = nil
        let previousConnection = connectionTask
        previousConnection?.cancel()
        connectionTask = nil
        let previous = activeRoom
        activeRoom = nil
        micError = ""
        connectionError = ""
        let earlierDisconnect = disconnectTask
        disconnectTask = Task {
            await earlierDisconnect?.value
            await previousAudience?.value
            await previousMicrophone?.value
            if let previous { await previous.disconnect() }
            await previousConnection?.value
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

    @objc public func setAudience(_ all: Bool, identitiesJson: String) {
        let data = Data(identitiesJson.utf8)
        let identities = (try? JSONSerialization.jsonObject(with: data)) as? [String] ?? []
        let nextIds = Set(identities.filter { !$0.isEmpty })
        guard audienceAll != all || audienceIds != nextIds else { return }
        audienceAll = all
        audienceIds = nextIds
        audienceReady = false
        audienceRevision += 1
        if let room = activeRoom, room.connectionState == .connected {
            updateAudience(room, serial: generation)
        }
    }

    private func updateAudience(_ room: Room, serial: Int) {
        guard audienceTask == nil else { return }
        let sids = room.remoteParticipants.values.compactMap { participant -> String? in
            guard let identity = participant.identity?.stringValue,
                  audienceIds.contains(identity) else { return nil }
            return participant.sid?.stringValue
        }.sorted()
        let fingerprint = "\(audienceAll):\(sids.joined(separator: ","))"
        if audienceReady && fingerprint == audienceFingerprint { return }
        audienceReady = false
        let revision = audienceRevision
        let allowAll = audienceAll
        audienceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == serial { self.audienceTask = nil } }
            do {
                let previousMicrophone = self.microphoneTask
                previousMicrophone?.cancel()
                await previousMicrophone?.value
                guard !Task.isCancelled, self.generation == serial, self.activeRoom === room,
                      self.audienceRevision == revision else { return }
                // Stop the old scope before narrowing it, then publish only after
                // the new subscriber permissions are accepted.
                if room.localParticipant.isMicrophoneEnabled() {
                    try await room.localParticipant.setMicrophone(enabled: false)
                }
                guard !Task.isCancelled, self.generation == serial, self.activeRoom === room,
                      self.audienceRevision == revision else { return }
                let permissions = sids.map {
                    ParticipantTrackPermission(participantSid: $0,
                                               allTracksAllowed: true,
                                               allowedTrackSids: [])
                }
                try await room.localParticipant.setTrackSubscriptionPermissions(
                    allParticipantsAllowed: allowAll, trackPermissions: permissions)
                guard self.generation == serial, self.activeRoom === room,
                      self.audienceRevision == revision else { return }
                self.audienceFingerprint = fingerprint
                self.audienceReady = true
                self.reconcileMicrophone(room, serial: serial)
            } catch {
                if !Task.isCancelled, self.generation == serial, self.activeRoom === room,
                   self.audienceRevision == revision { self.micError = "audience_failed" }
            }
        }
    }

    // Serialize toggles. A late publish completion may not re-enable the mic
    // after switching to Listen, leaving a room, or joining a different team.
    private func reconcileMicrophone(_ room: Room, serial: Int) {
        guard audienceReady else { return }
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
                    if !Task.isCancelled, self.generation == serial, self.activeRoom === room {
                        if self.hasRecordPermission() {
                            // Audio route/engine failures are recoverable: let the
                            // service reconnect with backoff and preserve Talk.
                            self.connectionError = "audio_device_failed"
                        } else { self.micError = "no_permission" }
                    }
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
        if let room, room.connectionState == .connected {
            updateAudience(room, serial: generation)
        }
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
            "mic_on": applicationActive && (room?.localParticipant.isMicrophoneEnabled() ?? false),
            "application_active": applicationActive, "audio_session_error": audioSessionError,
            "mic_error": micError, "permission": permission,
            "self_speaking": room?.localParticipant.isSpeaking ?? false,
            "speaking": speaking, "participants": participants,
            "audio_mode": session.category.rawValue,
            "session_mode": session.mode.rawValue,
            "platform_voice_processing": AudioManager.shared.isPlatformVoiceProcessingAllowed,
            "remote_audio_tracks": room?.remoteParticipants.values.reduce(0) { count, participant in
                count + participant.trackPublications.values.filter { $0.track is RemoteAudioTrack }.count
            } ?? 0,
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
