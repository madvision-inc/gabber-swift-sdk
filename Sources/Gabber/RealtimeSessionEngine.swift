import Foundation
import LiveKit
import os
import OpenAPIURLSession
import OpenAPIRuntime
import AVFoundation


public protocol RealtimeSessionEngineDelegate: AnyObject {
    func ConnectionStateChanged(state: Components.Schemas.SDKConnectionState) -> Void
    func MessagesChanged(messages: [Components.Schemas.SDKSessionTranscription]) -> Void
    func MicrophoneStateChanged(enabled: Bool) -> Void
    func AgentStateChanged(_ state: Components.Schemas.SDKAgentState) -> Void
    func AgentVolumeChanged(bands: [Float], volume: Float) -> Void
    func UserVolumeChanaged(bands: [Float], volume: Float) -> Void
    func RemainingSecondsChange(seconds: Float) -> Void
    func AgentError(msg: String) -> Void
}

public class RealtimeSessionEngine: RoomDelegate {

    private weak var delegate: RealtimeSessionEngineDelegate?
    
    private var agentParticipant: RemoteParticipant? = nil
    private var agentTrack: RemoteAudioTrack? = nil
    private var messages: [Components.Schemas.SDKSessionTranscription] = []
    private var agentVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var userVolumeVisualizer: TrackVolumeVisualizer = TrackVolumeVisualizer()
    private var _agentState = Components.Schemas.SDKAgentState.warmup
    
    public init(delegate: RealtimeSessionEngineDelegate) {
        self.delegate = delegate
    }
    
    private lazy var livekitRoom: Room = {
        return Room(delegate: self)
    }()
    
    //this should be private
    public var agentState: Components.Schemas.SDKAgentState {
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


    
    public func connect(opts: Components.Schemas.SDKConnectOptions) async throws {
        print("Attempting to connect to LiveKit room...")

        // Create the URLSessionTransport with the modified configuration

        var connectToken: String? = nil;
        var connectUrl: String? = nil;
        
        switch opts {
        case .case1(let payload):
            connectToken = payload.connection_details.token
            connectUrl = payload.connection_details.url
        case .case2(let payload):
            let token = payload.token
            var config = Configuration.init()
            config.dateTranscoder = .iso8601WithFractionalSeconds

            let sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.httpAdditionalHeaders = [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json"
            ]
            let transport = URLSessionTransport(configuration: URLSessionTransport.Configuration(session: URLSession(configuration: sessionConfiguration)))
            let client = Client(
                serverURL: URL(string: "https://api.gabber.dev")!,
                configuration: config,
                transport: transport
            )
            let jsonBody = Operations.startRealtimeSession.Input.Body.jsonPayload(config: payload.config)
            let resp = try await client.startRealtimeSession(.init(body: .json(jsonBody))).ok.body.json
            connectToken = resp.connection_details.token
            connectUrl = resp.connection_details.url
        }
        
        do {
            try await self.livekitRoom.connect(url: connectUrl!, token: connectToken!)
            print("LiveKit connection initiated.")
        } catch {
            print("Failed to connect to LiveKit room with error: \(error.localizedDescription)")
            self.delegate?.ConnectionStateChanged(state: .not_connected)  // Notify delegate of failure
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
        self.delegate?.ConnectionStateChanged(state: .not_connected)
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

            let agentState = Components.Schemas.SDKAgentState.init(rawValue: md.agent_state) ?? .warmup
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
                    self.delegate?.ConnectionStateChanged(state: .waiting_for_agent)
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
        decoder.dateDecodingStrategy = .custom { decoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = formatter.date(from: dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Expected date string to be ISO8601-formatted.")
        }
        
        if topic == "message" {
            do {
                print("NEIL \(String(decoding: data, as: UTF8.self))")
                let sm = try decoder.decode(Components.Schemas.SDKSessionTranscription.self, from: data)
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

private struct AgentErrorMessage: Decodable {
    var message: String
}
