//
//  Api.swift
//  Gabber
//
//  Created by gabber on 10/21/24.
//
import Foundation
import OpenAPIURLSession
import OpenAPIRuntime

public class Api {
    private var cachedClient: Client?
    
    public static func client(token: String) -> Client {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.httpAdditionalHeaders = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
        
        // Create the URLSessionTransport with the modified configuration
        let transport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(
                session: URLSession(configuration: sessionConfiguration)
            )
        )
        var config = Configuration.init()
        config.dateTranscoder = .iso8601WithFractionalSeconds
        // Create the Client
        let client = Client(
            serverURL: URL(string: "https://api.gabber.dev")!,
            configuration: config,
            transport: transport
        )
        
        return client
    }
}
