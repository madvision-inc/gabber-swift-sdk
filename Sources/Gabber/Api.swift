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
    private var tokenGenerator: () async throws -> String
    private var cachedClient: Client?
    
    public init(tokenGenerator: @escaping () async throws -> String) {
        self.tokenGenerator = tokenGenerator
    }
    
    private func getClient() async throws -> Client {
        if let client = cachedClient {
            return client
        } else {
            // Fetch the token asynchronously
            let token = try await tokenGenerator()
            
            // Create the session configuration
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
                serverURL: URL(string: "https://app.gabber.dev")!,
                configuration: config,
                transport: transport
            )
            
            // Cache the client for future use
            cachedClient = client
            
            return client
        }
    }
    
    public func getVoices() async throws -> PaginatedResponse<Voice> {
        let client = try await getClient()
        do {
            let response = try await client.get_sol_api_sol_v1_sol_voice_sol_list()
            let jsonResp = try response.ok.body.json
            let totalCount = Int(jsonResp.total_count)
            return PaginatedResponse(values: jsonResp.values, totalCount: totalCount, nextPage: jsonResp.next_page)
        } catch {
            print("NEIL error \(error)")
            throw error
        }

    }
    
}
