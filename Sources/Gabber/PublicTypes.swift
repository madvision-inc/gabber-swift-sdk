//
//  Types.swift
//  Gabber
//
//  Created by gabber on 10/22/24.
//

public typealias SessionMessage = Components.Schemas.SessionMessage
public typealias Voice = Components.Schemas.Voice
public typealias Persona = Components.Schemas.Persona
public typealias Scenario = Components.Schemas.Scenario
public typealias HistoryMessage = Components.Schemas.HistoryMessage

public struct PaginatedResponse<T: Codable>: Codable {
    public var values: [T]
    public var totalCount: Int
    public var nextPage: String?
}
