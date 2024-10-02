import Foundation
import LiveKit
import os


public protocol GabberDelegate: AnyObject {
    func ConnectionStateChanged(state: ConnectionState) -> Void
    func MessagesChanged(messages: [SessionMessage]) -> Void
    func MicrophoneStateChanged(enabled: Bool) -> Void
    func AgentStateChanged(_ state: AgentState) -> Void
    func AgentVolumeChanged(bands: [Float], volume: Float) -> Void
    func UserVolumeChanaged(bands: [Float], volume: Float) -> Void
    func RemainingSecondsChange(seconds: Float) -> Void
    func AgentError(msg: String) -> Void
}

public class Gabber: RoomDelegate {

    private weak var delegate: GabberDelegate?
    private var url: String
    private var token: String
    
    private var livekitRoom: Room
    private var agentParticipant: RemoteParticipant? = nil
    private var agentTrack: RemoteAudioTrack? = nil
    private var messages: [SessionMessage] = []
    private var agentVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var userVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var _agentState = AgentState.warmup
    
    //this should be private
    public var agentState: AgentState {
        set {
            _agentState = newValue
            NSLog("Agent state changed to: \(_agentState)")
            self.delegate?.AgentStateChanged(newValue)
        }
        get {
            return _agentState
        }
    }
    
    private var _remainingSeconds: Float? = nil
    private var remainingSeconds: Float? {
        set {
            _remainingSeconds = newValue
            if let v = newValue {
                NSLog("Remaining seconds updated: \(v)")
                self.delegate?.RemainingSecondsChange(seconds: v)
            }
        }
        get {
            return _remainingSeconds
        }
    }
    
    private var _microphoneEnabledState: Bool = false
    private var microphoneEnabledState: Bool {
        set {
            _microphoneEnabledState = newValue
            NSLog("Microphone state changed: \(newValue)")
            self.delegate?.MicrophoneStateChanged(enabled: newValue)
        }
        get {
            return _microphoneEnabledState
        }
    }

    public init(connectionDetails: ConnectionDetails, delegate: GabberDelegate) {
        self.url = connectionDetails.url
        self.token = connectionDetails.token
        self.livekitRoom = Room()
        self.delegate = delegate
        NSLog("Gabber initialized with URL: \(url) and Token: \(token.prefix(10))...")
    }
    
    public func connect() async throws {
        NSLog("Attempting to connect to LiveKit room...")
        
        do {
            try await self.livekitRoom.connect(url: self.url, token: self.token)
            NSLog("LiveKit connection initiated.")
        } catch {
            NSLog("Failed to connect to LiveKit room with error: \(error.localizedDescription)")
            self.delegate?.ConnectionStateChanged(state: .notConnected)  // Notify delegate of failure
            throw error  // Rethrow the error after logging it
        }
    }
    
    public func disconnect() async throws {
        NSLog("Disconnecting from LiveKit room...")
        await self.livekitRoom.disconnect()
        NSLog("Disconnected from LiveKit.")
    }
    
    public func setMicrophone(enabled: Bool) async throws {
        NSLog("Setting microphone state to \(enabled)...")
        try await self.livekitRoom.localParticipant.setMicrophone(enabled: enabled)
        NSLog("Microphone state set to \(enabled).")
    }
    
    public func sendChat(message: String) async throws {
        NSLog("Sending chat message: \(message)")
        try await self.livekitRoom.localParticipant.publish(data: message.data(using: .utf8)!, options: DataPublishOptions(topic: "chat_input"))
        NSLog("Chat message sent.")
    }
    
    private func resolveMicrophoneState() {
        self.microphoneEnabledState = self.livekitRoom.localParticipant.isMicrophoneEnabled()
        NSLog("Resolved microphone state: \(self.microphoneEnabledState)")
    }
    
    // Room Delegate
    public func roomDidConnect(_ room: Room) {
        NSLog("LiveKit room connected successfully")
        self.resolveMicrophoneState()
        self.delegate?.ConnectionStateChanged(state: .connected)
    }

    public func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        NSLog("LiveKit room disconnected with error: \(String(describing: error))")
        self.delegate?.ConnectionStateChanged(state: .notConnected)
    }

    
    public func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) {
        NSLog("Participant \(participant.identity) metadata updated: \(String(describing: metadata))")
        if participant.kind != .agent {
            return
        }
        guard let metadata = participant.metadata else {
            return
        }
        
        do {
            let md: AgentMetadata = try JSONDecoder().decode(AgentMetadata.self, from: Data(metadata.utf8))
            if let rs = md.remaining_seconds {
                self.remainingSeconds = rs
            }
            let agentState = try AgentState.from(md.agent_state)
            self.agentState = agentState
        } catch {
            NSLog("Error decoding agent metadata: \(error)")
        }
    }
    
    public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        // Ensure track is valid and log the correct type for Track.Sid
        if let track = publication.track {
            NSLog("Participant \(participant.identity) subscribed to track: \(track.sid)")
            if track.kind == .audio {
                if self.agentParticipant == nil {
                    self.agentParticipant = participant
                    if let remoteAudioTrack = track as? RemoteAudioTrack {
                        self.agentTrack = remoteAudioTrack
                        self.delegate?.ConnectionStateChanged(state: .connected)
                    }
                }
            }
        } else {
            NSLog("No track to subscribe to for participant \(participant.identity)")
        }
    }
    
    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        // Ensure correct handling of Track.Sid type
        if let trackSid = publication.track?.sid {
            NSLog("Participant \(participant.identity) unsubscribed from track: \(trackSid)")
            if trackSid == self.agentTrack?.sid {
                self.agentParticipant = nil
                self.agentTrack = nil
                if self.livekitRoom.connectionState == .connected {
                    self.delegate?.ConnectionStateChanged(state: .waitingForAgent)
                }
            }
        } else {
            NSLog("No track found for unsubscription")
        }
    }
    
    public func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String) {
        NSLog("Received data for topic \(topic) from participant \(String(describing: participant?.identity))")
        if participant?.identity != self.agentParticipant?.identity {
            return
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if topic == "message" {
            do {
                let sm = try decoder.decode(SessionMessage.self, from: data)
                NSLog("Decoded session message: \(sm.text)")
                if let index = self.messages.firstIndex(where: { $0.id == sm.id }) {
                    self.messages[index] = sm
                } else {
                    self.messages.append(sm)
                }
                self.delegate?.MessagesChanged(messages: self.messages)
            } catch {
                NSLog("Error decoding session message: \(error)")
            }
        } else if topic == "error" {
            do {
                let ae = try decoder.decode(AgentErrorMessage.self, from: data)
                NSLog("Agent error received: \(ae.message)")
                self.delegate?.AgentError(msg: ae.message)
            } catch {
                NSLog("Error decoding agent error: \(error)")
            }
        }
    }
    
    public func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if let trackSid = publication.track?.sid {
            NSLog("Local participant \(participant.identity) published track with sid: \(trackSid)")
        } else {
            NSLog("Local participant \(participant.identity) published track with unknown sid")
        }
        self.resolveMicrophoneState()
    }

    public func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        if let trackSid = publication.track?.sid {
            NSLog("Local participant \(participant.identity) unpublished track with sid: \(trackSid)")
        } else {
            NSLog("Local participant \(participant.identity) unpublished track with unknown sid")
        }
        self.resolveMicrophoneState()
    }

    public func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        if let trackSid = trackPublication.track?.sid {
            NSLog("Participant \(participant.identity) track \(trackSid) muted state changed to: \(isMuted)")
        } else {
            NSLog("Participant \(participant.identity) track has unknown sid, muted state changed to: \(isMuted)")
        }
        self.resolveMicrophoneState()
    }

    
    private struct AgentMetadata: Decodable {
        public var agent_state: String
        public var remaining_seconds: Float?
    }
}

public enum ConnectionState {
    case notConnected, connecting, waitingForAgent, connected
}

public enum AgentState {
    public enum AgentStateError: Error {
        case parseError(_ state: String)
    }
    
    case warmup, listening, thinking, speaking, timeLimitExceeded
    
    static func from(_ str: String) throws -> AgentState {
        if str == "warmup" {
            return .warmup
        } else if str == "listening" {
            return .listening
        } else if str == "thinking" {
            return .thinking
        } else if str == "speaking" {
            return .speaking
        } else if str == "time_limit_exceeded" {
            return .timeLimitExceeded
        }
        throw AgentStateError.parseError("unhandled agent state")
    }
}

public struct ConnectionDetails {
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }
}

public struct SessionMessage: Decodable {
    public var id: Int     // Make id public
    public var agent: Bool
    public var final: Bool
    public var createdAt: Date
    public var speakingEndedAt: Date
    public var deletedAt: Date?
    public var session: String
    public var text: String // Make text public
}

private struct AgentErrorMessage: Decodable {
    var message: String
}
