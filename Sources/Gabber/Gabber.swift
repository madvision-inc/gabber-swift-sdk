// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import LiveKit

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
    private weak var delegate: GabberDelegate?;
    private var url: String;
    private var token: String;
    
    private var livekitRoom: Room;
    private var agentParticipant: RemoteParticipant? = nil
    private var agentTrack: RemoteAudioTrack? = nil
    private var messages: [SessionMessage] = []
    private var agentVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var userVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var _agentState = AgentState.warmup
    private var agentState: AgentState {
        set {
            _agentState = newValue
            self.delegate?.AgentStateChanged(newValue)
        }
        get{
            return _agentState
        }
    }
    private var _remainingSeconds: Float? = nil
    private var remainingSeconds: Float? {
        set {
            _remainingSeconds = newValue
            if let v = newValue {
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
            self.delegate?.MicrophoneStateChanged(enabled: newValue)
        }
        get {
            return _microphoneEnabledState
        }
    }

    init(connectionDetails: ConnectionDetails, delegate: GabberDelegate) {
        self.url = connectionDetails.url
        self.token = connectionDetails.token
        self.livekitRoom = Room()
        self.delegate = delegate
    }
    
    public func connect() async throws {
        try await self.livekitRoom.connect(url: self.url, token: self.token)
    }
    
    public func disconnect() async throws {
        await self.livekitRoom.disconnect()
    }
    
    public func setMicrophone(enabled: Bool) async throws {
        try await self.livekitRoom.localParticipant.setMicrophone(enabled: enabled)
    }
    
    public func sendChat(message: String) async throws {
        try await self.livekitRoom.localParticipant.publish(data: message.data(using: .utf8)!, options: DataPublishOptions(topic: "chat_input"))
    }
    
    private func resolveMicrophoneState() {
        self.microphoneEnabledState = self.livekitRoom.localParticipant.isMicrophoneEnabled()
    }
    
    // Room Delegate
    public func roomDidConnect(_ room: Room) {
        self.resolveMicrophoneState()
        self.delegate?.ConnectionStateChanged(state: .waitingForAgent)
    }
    
    public func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        self.resolveMicrophoneState()
        self.delegate?.ConnectionStateChanged(state: .notConnected)
    }
    
    public func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) {
        if participant.kind != .agent {
            return;
        }
        guard let metadata = participant.metadata else {
            return
        }

        var d = metadata.data(using: .utf8)!
        do {
            let md: AgentMetadata = try JSONDecoder().decode(AgentMetadata.self, from: d)
            if let rs = md.remaining_seconds {
                self.remainingSeconds = md.remaining_seconds
            }
            let agentState = try AgentState.from(md.agent_state)
            self.agentState = agentState
        } catch {
            print("Error decoding agent metadata");
        }
    }
    
    public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track else {
            return
        }
        if track.kind != .audio {
            return
        }
        if self.agentParticipant != nil {
            return
        }
        guard let audioTrack = track as? AudioTrack else {
            return
        }
        guard let remoteAudioTrack = track as? RemoteAudioTrack else {
            return
        }
        
        self.agentParticipant = participant
        self.agentTrack = remoteAudioTrack
        self.delegate?.ConnectionStateChanged(state: .connected)
    }
    
    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        if publication.track?.sid != self.agentTrack?.sid {
            print("Unsubscribing from unkown track")
            return
        }
        self.agentParticipant = nil
        self.agentTrack = nil
        if self.livekitRoom.connectionState == .connected {
            self.delegate?.ConnectionStateChanged(state: .waitingForAgent)
        }
    }
    
    public func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String) {
        if participant?.identity != self.agentParticipant {
            return;
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = String(decoding: data, as: UTF8.self)
        if topic == "message" {
            do {
                let sm = try decoder.decode(SessionMessage.self, from: data)
                for  i in 0...self.messages.count {
                    if self.messages[i].id == sm.id {
                        self.messages[i] = sm
                        self.delegate?.MessagesChanged(messages: self.messages)
                        return
                    }
                }
                self.messages.append(sm)
                self.delegate?.MessagesChanged(messages: self.messages)
            } catch {
                print("Error decoding session message")
            }
        } else if topic == "error" {
            do {
                let ae = try decoder.decode(AgentErrorMessage.self, from: data)
                self.delegate?.AgentError(msg: ae.message)
            } catch {
                print("Agent error decode error")
            }
        }
    }
    
    public func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        //      console.log("Local track published", publication, participant);
//      if (publication.kind === Track.Kind.Audio) {
//        this.userVolumeVisualizer.setTrack(
//          publication.audioTrack as LocalAudioTrack
//        );
//      }
        self.resolveMicrophoneState();
    }
    
    public func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        self.resolveMicrophoneState()
    }
    
    public func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
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
            return AgentState.warmup
        } else if str == "listening" {
            return AgentState.listening
        } else if str == "thinking" {
            return AgentState.thinking
        } else if str == "speaking" {
            return AgentState.speaking
        } else if str == "time_limit_exceeded" {
            return AgentState.timeLimitExceeded
        }
        throw AgentStateError.parseError("unhandled agent state")
    }
}

public struct ConnectionDetails {
    var url: String
    var token: String
}

public struct SendChatMessageParams {
    var text: String
}

public struct SessionMessage: Decodable {
    var id: Int
    var agent: Bool
    var final: Bool
    var createdAt: Date
    var speakingEndedAt: Date
    var deletedAt: Date?
    var session: String
    var text: String
}


private struct AgentErrorMessage: Decodable {
    var message: String
}

