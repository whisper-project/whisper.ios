// Copyright 2024 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation

final class ListenConversation: Conversation, Hashable, Encodable, Decodable {
	private(set) var id: String
	fileprivate(set) var name: String = ""
	fileprivate(set) var owner: String = ""
	fileprivate(set) var ownerName: String = ""
	fileprivate(set) var lastListened: Date = Date.distantPast

	var authorized: Bool { get { lastListened != Date.distantPast } }

	fileprivate init(uuid: String? = nil, name: String? = nil) {
		self.id = uuid ?? UUID().uuidString
		self.name = name ?? ""
	}

	// equality by id
	static func ==(_ left: ListenConversation, _ right: ListenConversation) -> Bool {
		return left.id == right.id
	}

	// hash by id
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}

	// decreasing sort by last-used date then increasing sort by name (then ID) within date bucket
	static func <(_ left: ListenConversation, _ right: ListenConversation) -> Bool {
		if left.lastListened == right.lastListened {
			if left.name == right.name {
				return left.id < right.id
			} else {
				return left.name < right.name
			}
		} else {
			return left.lastListened > right.lastListened
		}
	}
}

final class ListenProfile: Codable {
	static private let saveName = PreferenceData.profileRoot + "ListenProfile"

	var id: String
	private var table: [String: ListenConversation]
	private var timestamp: Int
	private var serverPassword: String = ""

	private enum CodingKeys: String, CodingKey {
		case id, table, timestamp
	}

	init(_ profileId: String) {
		id = profileId
		table = [:]
		timestamp = Int(Date.now.timeIntervalSince1970)
		save()
	}

	/// The sorted list of listen conversations
	func conversations() -> [ListenConversation] {
		let sorted = Array(table.values).sorted()
		return sorted
	}

	func getConversation(_ id: String) -> ListenConversation? {
		return table[id]
	}

	func fromMyWhisperConversation(_ conversation: WhisperConversation) -> ListenConversation {
		let c = ListenConversation(uuid: conversation.id)
		c.name = conversation.name
		c.owner = id
		c.ownerName = UserProfile.shared.username
		c.lastListened = Date.now
		return c
	}

	/// get a listen conversation from a web link
	func fromLink(_ url: String) -> ListenConversation? {
		guard let (id, name) = PreferenceData.publisherUrlToConversationId(url: url) else {
			return nil
		}
		if let existing = table[id] {
			return existing
		} else {
			return ListenConversation(uuid: id, name: name)
		}
	}

	/// get a listen conversation for a Whisperer's invite
	func forInvite(info: WhisperProtocol.ClientInfo) -> ListenConversation {
		if let c = table[info.conversationId] {
			var changed = false
			if !info.conversationName.isEmpty && info.conversationName != c.name {
				c.name = info.conversationName
				changed = true
			}
			if !info.profileId.isEmpty && info.profileId != c.owner {
				c.owner = info.profileId
				changed = true
			}
			if !info.username.isEmpty && info.username != c.ownerName {
				c.ownerName = info.username
				changed = true
			}
			if changed {
				save()
			}
			return c
		}
		let c =  ListenConversation(uuid: info.conversationId)
		c.name = info.conversationName
		c.owner = info.profileId
		c.ownerName = info.username
		return c
	}

	/// Add a newly used conversation for a Listener
	func addForInvite(info: WhisperProtocol.ClientInfo) -> ListenConversation {
		let c = forInvite(info: info)
		guard serverPassword.isEmpty || info.profileId != id else {
			// in a shared profile, we never add one of our own conversations
			return c
		}
		if table[c.id] == nil {
			logger.info("Adding new listen conversation")
			table[c.id] = c
		}
		c.lastListened = Date.now
		save()
		return c
	}

	func delete(_ id: String) {
		logger.info("Removing listen conversation \(id)")
		if table.removeValue(forKey: id) != nil {
			save()
		}
	}

	private func save(verb: String = "PUT", localOnly: Bool = false) {
		if !localOnly {
			timestamp = Int(Date.now.timeIntervalSince1970)
		}
		guard let data = try? JSONEncoder().encode(self) else {
			fatalError("Cannot encode listen profile: \(self)")
		}
		guard data.saveJsonToDocumentsDirectory(ListenProfile.saveName) else {
			fatalError("Cannot save listen profile to Documents directory")
		}
		if !localOnly && !serverPassword.isEmpty {
			saveToServer(data: data, verb: verb)
		}
	}

	static func load(_ profileId: String, serverPassword: String) -> ListenProfile? {
		if let data = Data.loadJsonFromDocumentsDirectory(ListenProfile.saveName),
		   let profile = try? JSONDecoder().decode(ListenProfile.self, from: data)
		{
			if profileId == profile.id {
				profile.serverPassword = serverPassword
				return profile
			}
			logger.warning("Asked to load profile with id \(profileId), deleting saved profile with id \(profile.id)")
			Data.removeJsonFromDocumentsDirectory(ListenProfile.saveName)
		}
		return nil
	}

	private func saveToServer(data: Data, verb: String = "PUT") {
		let path = "/api/v2/listenProfile" + (verb == "PUT" ? "/\(id)" : "")
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for listen profile upload")
		}
		logger.info("\(verb) of listen profile to server, current timestamp: \(self.timestamp)")
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
				if let profile = try? JSONDecoder().decode(ListenProfile.self, from: data) {
					logger.info("Received updated listen profile, timestamp is \(profile.timestamp)")
					self.table = profile.table
					self.timestamp = profile.timestamp
					save(localOnly: true)
					notifyChange?()
				} else {
					logAnomaly("Received invalid listen profile data: \(String(decoding: data, as: UTF8.self))")
				}
			} else if code == 404 {
				// this is supposed to be a shared profile, but the server doesn't have it?!
				logAnomaly("Found no listen profile on server when updating, uploading one")
				save(verb: "POST")
			}
		}
		let path = "/api/v2/listenProfile/\(id)"
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for listen profile download")
		}
		var request = URLRequest(url: url)
		request.setValue("Bearer \(serverPassword)", forHTTPHeaderField: "Authorization")
		request.setValue("\"\(self.timestamp)\"", forHTTPHeaderField: "If-None-Match")
		request.setValue(PreferenceData.clientId, forHTTPHeaderField: "X-Client-Id")
		request.httpMethod = "GET"
		Data.executeJSONRequest(request, handler: handler)
	}

	func startSharing(serverPassword: String, ownConversations: [WhisperConversation] = []) {
		self.serverPassword = serverPassword
		// if we own any of our past listened conversations, remove it,
		// because we will now see all of our whispered conversations automatically
		for conversation in ownConversations {
			table.removeValue(forKey: conversation.id)
		}
		save(verb: "POST")
	}

	func loadShared(id: String, serverPassword: String, completionHandler: @escaping (Int) -> Void) {
		func handler(_ code: Int, _ data: Data) {
			if code < 200 || code >= 300 {
				completionHandler(code)
			} else if let profile = try? JSONDecoder().decode(ListenProfile.self, from: data)
			{
				self.id = id
				self.serverPassword = serverPassword
				self.table = profile.table
				self.timestamp = profile.timestamp
				save(localOnly: true)
				completionHandler(200)
			} else {
				logAnomaly("Received invalid listen profile data: \(String(decoding: data, as: UTF8.self))")
				completionHandler(-1)
			}
		}
		let path = "/api/v2/listenProfile/\(id)"
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for listen profile download")
		}
		var request = URLRequest(url: url)
		request.setValue("Bearer \(serverPassword)", forHTTPHeaderField: "Authorization")
		request.setValue(PreferenceData.clientId, forHTTPHeaderField: "X-Client-Id")
		request.setValue("\"  impossible-timestamp   \"", forHTTPHeaderField: "If-None-Match")
		request.httpMethod = "GET"
		Data.executeJSONRequest(request, handler: handler)
	}
}
