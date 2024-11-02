import Foundation
import LiveKit
import os
import OpenAPIURLSession
import OpenAPIRuntime
import AVFoundation


public protocol SessionDelegate: AnyObject {
    func ConnectionStateChanged(state: ConnectionState) -> Void
    func MessagesChanged(messages: [SessionTranscription]) -> Void
    func MicrophoneStateChanged(enabled: Bool) -> Void
    func AgentStateChanged(_ state: AgentState) -> Void
    func AgentVolumeChanged(bands: [Float], volume: Float) -> Void
    func UserVolumeChanaged(bands: [Float], volume: Float) -> Void
    func RemainingSecondsChange(seconds: Float) -> Void
    func AgentError(msg: String) -> Void
}

public class Session: RoomDelegate {

    private weak var delegate: SessionDelegate?
    private var tokenGenerator: () async throws -> String
    
    private var agentParticipant: RemoteParticipant? = nil
    private var agentTrack: RemoteAudioTrack? = nil
    private var messages: [SessionTranscription] = []
    private var agentVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var userVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var _agentState = AgentState.warmup
    
    public init(tokenGenerator: @escaping () async throws -> String, delegate: SessionDelegate) {
        self.tokenGenerator = tokenGenerator
        self.delegate = delegate
    }
    
    private lazy var livekitRoom: Room = {
        return Room(delegate: self)
    }()
    
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
            if(newValue) {
                let audioSession = AVAudioSession.sharedInstance()
                do {
                    try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: .defaultToSpeaker)
                    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                } catch {
                    print("Audio session configuration failed: \(error)")
                }
            }
            self.delegate?.MicrophoneStateChanged(enabled: newValue)
        }
        get {
            return _microphoneEnabledState
        }
    }


    
    public func connect(opts: ConnectOptions) async throws {
        print("Attempting to connect to LiveKit room...")
        
        let token = try await self.tokenGenerator()
        let url: String
        let connectToken: String
        let sessionConfiguration = URLSessionConfiguration.default

        sessionConfiguration.httpAdditionalHeaders = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
        var config = Configuration.init()
        config.dateTranscoder = .iso8601WithFractionalSeconds

        // Create the URLSessionTransport with the modified configuration
        let transport = URLSessionTransport(configuration: URLSessionTransport.Configuration(session: URLSession(configuration: sessionConfiguration)))
        let client = Client(
            serverURL: URL(string: "https://app.gabber.dev")!,
            configuration: config,
            transport: transport
        )
        
        switch opts {
        case .connectionDetails(let _url, let _connectToken):
            url = _url
            connectToken = _connectToken
        case .sessionStartRequest(let req):
            let resp = try await client.post_sol_api_sol_v1_sol_session_sol_start(body: .json(req)).ok.body.json
            connectToken = resp.connection_details.token!
            url = resp.connection_details.url!
        }
        
        
        do {
            try await self.livekitRoom.connect(url: url, token: connectToken)
            print("LiveKit connection initiated.")
        } catch {
            print("Failed to connect to LiveKit room with error: \(error.localizedDescription)")
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
        print("Sending chat message: \(message)")
        let messageData = ["text": message]
        let jsonData = try JSONSerialization.data(withJSONObject: messageData, options: [])
        try await self.livekitRoom.localParticipant.publish(data: jsonData, options: DataPublishOptions(topic: "chat_input"))
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
        print("Subscribed to track")
        // Ensure track is valid and log the correct type for Track.Sid
        if let track = publication.track {
            if track.kind == .audio {
                if self.agentParticipant == nil {
                    self.agentParticipant = participant
                    if let remoteAudioTrack = track as? RemoteAudioTrack {
                        print("Subscribed to agent track")
                        self.agentTrack = remoteAudioTrack
                        self.delegate?.ConnectionStateChanged(state: .connected)
                    }
                }
            }
        } else {
            print("No track to subscribe to for participant \(participant.identity?.stringValue ?? "")")
        }
    }
    
    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        // Ensure correct handling of Track.Sid type
        if let trackSid = publication.track?.sid {
            if trackSid == self.agentTrack?.sid {
                self.agentParticipant = nil
                self.agentTrack = nil
                if self.livekitRoom.connectionState == .connected {
                    self.delegate?.ConnectionStateChanged(state: .waitingForAgent)
                }
            }
        } else {
        }
    }
    
    public func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String) {
        print("Received data for topic \(topic) from participant \(String(describing: participant?.identity))")
        if participant?.identity != self.agentParticipant?.identity {
            return
        }
        
        let decoder = JSONDecoder()
        

        if topic == "message" {
            do {
                let sm = try decoder.decode(SessionTranscription.self, from: data)
                if let index = self.messages.firstIndex(where: { $0.id == sm.id && $0.agent == sm.agent }) {
                    self.messages[index] = sm
                } else {
                    self.messages.append(sm)
                }
                self.delegate?.MessagesChanged(messages: self.messages)
            } catch {
                print("Error decoding message \(error)")
            }
        } else if topic == "error" {
            do {
                let ae = try decoder.decode(AgentErrorMessage.self, from: data)
                print("Agent error received: \(ae.message)")
                self.delegate?.AgentError(msg: ae.message)
            } catch {
                print("Error decoding agent error: \(error)")
            }
        }
    }
    
    public func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if let trackSid = publication.track?.sid {
            print("Local participant \(participant.identity?.stringValue ?? "") published track with sid: \(trackSid)")
        } else {
            print("Local participant \(participant.identity?.stringValue ?? "") published track with unknown sid")
        }
        self.resolveMicrophoneState()
    }

    public func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        if let trackSid = publication.track?.sid {
            print("Local participant \(participant.identity?.stringValue ?? "") unpublished track with sid: \(trackSid)")
        } else {
            print("Local participant \(participant.identity?.stringValue ?? "") unpublished track with unknown sid")
        }
        self.resolveMicrophoneState()
    }

    public func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        if let trackSid = trackPublication.track?.sid {
            print("Participant \(participant.identity?.stringValue ?? "") track \(trackSid) muted state changed to: \(isMuted)")
        } else {
            print("Participant \(participant.identity?.stringValue ?? "") track has unknown sid, muted state changed to: \(isMuted)")
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

private struct AgentErrorMessage: Decodable {
    var message: String
}

public enum ConnectOptions {
    case sessionStartRequest(req: Components.Schemas.SessionStartRequest)
    case connectionDetails(url: String, token: String)
}

public struct SessionTranscription: Decodable {
    public var id: Int
    public var agent: Bool
    public var text: String
    
    public var uniqueId: String {
        "\(agent ? "agent" : "user")_\(id)"
    }
}
