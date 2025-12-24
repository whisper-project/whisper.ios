// Copyright 2024 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import CryptoKit

final class WhisperConversation: Conversation, Codable, Hashable {
	private(set) var id: String
	fileprivate(set) var name: String = ""
	fileprivate(set) var allowed: [String: String] = [:]	// profile ID to username mapping

	fileprivate init(uuid: String? = nil) {
		self.id = uuid ?? UUID().uuidString
	}

	// equality by id
	static func ==(_ left: WhisperConversation, _ right: WhisperConversation) -> Bool {
		return left.id == right.id
	}

	// hash by id
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}

	// lexicographic ordering by name
	// since two conversations can have the same name, we fall back
	// to lexicographic ID order to break ties with stability.
	static func <(_ left: WhisperConversation, _ right: WhisperConversation) -> Bool {
		if left.name == right.name {
			return left.id < right.id
		} else {
			return left.name < right.name
		}
	}
}


struct ListenerInfo: Identifiable {
	let id: String
	let username: String
}

final class WhisperProfile: Codable {
	static private let saveName = PreferenceData.profileRoot + "WhisperProfile"

	private var id: String
	private var table: [String: WhisperConversation]
	private var defaultId: String
	private var lastId: String?
	private var timestamp: Int
	private var serverPassword: String = ""

	private enum CodingKeys: String, CodingKey {
		case id, table, defaultId, lastId, timestamp
	}

	init(_ profileId: String, profileName: String) {
		id = profileId
		table = [:]
		defaultId = "none"
		lastId = nil
		timestamp = Int(Date.now.timeIntervalSince1970)
		ensureFallback(profileName)
	}

	var lastUsed: WhisperConversation? {
		get {
			if let val = lastId, let existing = table[val] {
				return existing
			}
			return nil
		}
		set(c) {
			guard let c = c else {
				lastId = nil
				return
			}
			guard c.id != lastId else {
				// nothing to do
				return
			}
			guard let existing = table[c.id] else {
				fatalError("Tried to set last whisper conversation to one not in whisper table")
			}
			lastId = existing.id
			timestamp = Int(Date.now.timeIntervalSince1970)
			save()
		}
	}

	var fallback: WhisperConversation {
		get {
			return ensureFallback()
		}
		set(c) {
			guard c.id != defaultId else {
				// nothing to do
				return
			}
			guard let existing = table[c.id] else {
				fatalError("Tried to set default whisper conversation to one not in whisper table")
			}
			defaultId = existing.id
			timestamp = Int(Date.now.timeIntervalSince1970)
			save()
		}
	}

	// make sure there is a default conversation, and return it
	@discardableResult private func ensureFallback(_ profileName: String? = nil) -> WhisperConversation {
		if let c = table[defaultId] {
			return c
		} else if let firstC = table.first?.value {
			defaultId = firstC.id
			save()
			return firstC
		} else {
			let newC = newInternal(profileName)
			defaultId = newC.id
			save()
			return newC
		}
	}

	private func newInternal(_ profileName: String? = nil) -> WhisperConversation {
		let new = WhisperConversation()
		new.name = "Conversation \(table.count + 1)"
		logger.info("Adding whisper conversation \(new.id) (\(new.name))")
		table[new.id] = new
		postConversation(new, profileName: profileName)
		return new
	}

	func conversations() -> [WhisperConversation] {
		ensureFallback()
		let sorted = Array(table.values).sorted()
		return sorted
	}

	func getConversation(_ id: String) -> WhisperConversation? {
		return table[id]
	}

	/// Create a new whisper conversation
	@discardableResult func new() -> WhisperConversation {
		let c = newInternal()
		save()
		return c
	}

	/// Change the name of a conversation
	func rename(_ conversation: WhisperConversation, name: String) {
		guard let c = table[conversation.id] else {
			fatalError("Not a Whisper conversation: \(conversation.id)")
		}
		c.name = name
		postConversation(c)
		save()
	}

	/// add a user to a conversation and/or update their name in the conversation
	func addListener(_ conversation: WhisperConversation, info: WhisperProtocol.ClientInfo) {
		guard info.profileId != id || serverPassword.isEmpty else {
			// if our profile is shared, we never add ourselves as a listener
			return
		}
		if let username = conversation.allowed[info.profileId], username == info.username {
			// nothing to do
			return
		}
		conversation.allowed[info.profileId] = info.username
		save()
	}

	/// find out whether a user has been added to a whisper conversation
	func isListener(_ conversation: WhisperConversation, info: WhisperProtocol.ClientInfo) -> ListenerInfo? {
		guard let username = conversation.allowed[info.profileId] else {
			return nil
		}
		return ListenerInfo(id: info.profileId, username: username)
	}

	/// remove user from a whisper conversation
	func removeListener(_ conversation: WhisperConversation, profileId: String) {
		if conversation.allowed.removeValue(forKey: profileId) != nil {
			save()
		}
	}

	/// list listeners for a whisper conversation
	func listeners(_ conversation: WhisperConversation) -> [ListenerInfo] {
		conversation.allowed.map({ k, v in ListenerInfo(id: k, username: v) })
	}

	/// Remove a conversation
	func delete(_ conversation: WhisperConversation) {
		logger.info("Removing whisper conversation \(conversation.id) (\(conversation.name))")
		if table.removeValue(forKey: conversation.id) != nil {
			if (defaultId == conversation.id) {
				ensureFallback()
			} else {
				save()
			}
		}
	}

	private func save(verb: String = "PUT", localOnly: Bool = false) {
		if !localOnly {
			timestamp = Int(Date.now.timeIntervalSince1970)
		}
		guard let data = try? JSONEncoder().encode(self) else {
			fatalError("Cannot encode whisper profile: \(self)")
		}
		guard data.saveJsonToDocumentsDirectory(WhisperProfile.saveName) else {
			fatalError("Cannot save whisper profile to Documents directory")
		}
		if !localOnly && !serverPassword.isEmpty {
			saveToServer(data: data, verb: verb)
		}
	}

	static func load(_ profileId: String, serverPassword: String) -> WhisperProfile? {
		if let data = Data.loadJsonFromDocumentsDirectory(WhisperProfile.saveName),
		   let profile = try? JSONDecoder().decode(WhisperProfile.self, from: data)
		{
			if profileId == profile.id {
				profile.serverPassword = serverPassword
				return profile
			}
			logger.warning("Asked to load profile with id \(profileId), deleting saved profile with id \(profile.id)")
			Data.removeJsonFromDocumentsDirectory(WhisperProfile.saveName)
		}
		return nil
	}

	private func saveToServer(data: Data, verb: String = "PUT") {
		let path = "/api/v2/whisperProfile" + (verb == "PUT" ? "/\(id)" : "")
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for whisper profile upload")
		}
		logger.info("\(verb) of  whisper profile to server, current timestamp: \(self.timestamp)")
		var request = URLRequest(url: url)
		request.httpMethod = verb
		if verb == "PUT" {
			request.setValue("Bearer \(serverPassword)", forHTTPHeaderField: "Authorization")
		}
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(PreferenceData.clientId, forHTTPHeaderField: "X-Client-Id")
		request.httpBody = data
		Data.executeJSONRequest(request)
	}

	func update(_ notifyChange: (() -> Void)? = nil) {
		guard !serverPassword.isEmpty else {
			// not a shared profile, so no way to update
			return
		}
		func handler(_ code: Int, _ data: Data) {
			if code == 200 {
				if let profile = try? JSONDecoder().decode(WhisperProfile.self, from: data) {
					logger.info("Received updated whisper profile, timestamp is \(profile.timestamp)")
					self.table = profile.table
					self.defaultId = profile.defaultId
					self.timestamp = profile.timestamp
					save(localOnly: true)
					notifyChange?()
				} else {
					logAnomaly("Received invalid whisper profile data: \(String(decoding: data, as: UTF8.self))")
				}
			} else if code == 404 {
				// this is supposed to be a shared profile, but the server doesn't have it?!
				logAnomaly("Found no whisper profile on server when updating, uploading one")
				save(verb: "POST")
			}
		}
		let path = "/api/v2/whisperProfile/\(id)"
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for whisper profile download")
		}
		var request = URLRequest(url: url)
		request.setValue("Bearer \(serverPassword)", forHTTPHeaderField: "Authorization")
		request.setValue("\"\(self.timestamp)\"", forHTTPHeaderField: "If-None-Match")
		request.setValue(PreferenceData.clientId, forHTTPHeaderField: "X-Client-Id")
		request.httpMethod = "GET"
		Data.executeJSONRequest(request, handler: handler)
	}

	func startSharing(serverPassword: String) {
		self.serverPassword = serverPassword
		// if we were an allowed listener for one of our conversations,
		// remove us, because we are now automatically allowed
		for conversation in table.values {
			conversation.allowed.removeValue(forKey: id)
		}
		save(verb: "POST")
	}

	func loadShared(id: String, serverPassword: String, completionHandler: @escaping (Int) -> Void) {
		func handler(_ code: Int, _ data: Data) {
			if code < 200 || code >= 300 {
				completionHandler(code)
			} else if let profile = try? JSONDecoder().decode(WhisperProfile.self, from: data)
			{
				self.id = id
				self.serverPassword = serverPassword
				self.table = profile.table
				self.defaultId = profile.defaultId
				self.timestamp = profile.timestamp
				save(localOnly: true)
				completionHandler(200)
			} else {
				logAnomaly("Received invalid whisper profile data: \(String(decoding: data, as: UTF8.self))")
				completionHandler(-1)
			}
		}
		let path = "/api/v2/whisperProfile/\(id)"
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for whisper profile download")
		}
		var request = URLRequest(url: url)
		request.setValue("Bearer \(serverPassword)", forHTTPHeaderField: "Authorization")
		request.setValue(PreferenceData.clientId, forHTTPHeaderField: "X-Client-Id")
		request.setValue("\"  impossible-timestamp   \"", forHTTPHeaderField: "If-None-Match")
		request.httpMethod = "GET"
		Data.executeJSONRequest(request, handler: handler)
	}

	private func postConversation(_ conversation: WhisperConversation, profileName: String? = nil) {
		let path = "/api/v2/conversation"
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for conversation upload")
		}
		let localValue = [
			"id": conversation.id,
			"name": conversation.name,
			"ownerId": id,
			"ownerName": profileName ?? UserProfile.shared.username
		]
		guard let localData = try? JSONSerialization.data(withJSONObject: localValue) else {
			fatalError("Can't encode user profile data: \(localValue)")
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(PreferenceData.clientId, forHTTPHeaderField: "X-Client-Id")
		request.httpBody = localData
		logger.info("Posting updated conversation \(conversation.id) to the server")
		Data.executeJSONRequest(request)
	}
}
