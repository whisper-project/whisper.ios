// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import CoreBluetooth
import CryptoKit

enum OperatingMode: Int {
    case ask = 0, listen = 1, whisper = 2
}

struct PreferenceData {
    private static var defaults = UserDefaults.standard
    
    // publisher URLs
    #if DEBUG
	static private let altServer = ProcessInfo.processInfo.environment["WHISPER_SERVER"] != nil
	static let whisperServer = ProcessInfo.processInfo.environment["WHISPER_SERVER"] ?? "https://stage.whisper.clickonetwo.io"
	static let profileRoot = altServer ? "dev-" : "stage-"
    #else
    static let whisperServer = "https://whisper.clickonetwo.io"
	static let profileRoot = ""
    #endif
    static func publisherUrlToConversationId(url: String) -> (String, String)? {
		let expectedPrefix = whisperServer + "/listen/"
		if url.starts(with: expectedPrefix) {
			let tailEnd = url.index(expectedPrefix.endIndex, offsetBy: 36)
			let tail = url[expectedPrefix.endIndex..<tailEnd]
			if tail.wholeMatch(of: /[-a-zA-Z0-9]{36}/) != nil {
				let rest = url.suffix(from: url.index(tailEnd, offsetBy: 1))
				if rest.isEmpty {
					return (String(tail), String(tail.suffix(12)))
				} else {
					return (String(tail), String(rest))
				}
			}
		}
        return nil
    }
    static func publisherUrl(_ conversation: any Conversation) -> String {
		let urlName = conversation.name.compactMap {char in
			if char.isLetter || char.isNumber {
				return String(char)
			} else {
				return "-"
			}
		}.joined()
		return "\(whisperServer)/listen/\(conversation.id)/\(urlName)"
    }
	static let publisherUrlEventMatchString = "\(whisperServer)/listen/*"

    // server (and Ably) client ID for this device
    static var clientId: String {
        if let id = defaults.string(forKey: "whisper_client_id") {
            return id
        } else {
            let id = UUID().uuidString
            defaults.setValue(id, forKey: "whisper_client_id")
            return id
        }
    }
    
    // client secrets for TCP transport
    //
    // Secrets rotate.  The client generates its first secret, and always
    // sets that as both the current and prior secret.  After that, every
    // time the server sends a new secret, the current secret rotates to
    // be the prior secret.  We send the prior secret with every launch,
    // because this allows the server to know when we've gone out of sync
    // (for example, when a client moves from apns dev to apns prod),
    // and it rotates the secret when that happens.  We sign auth requests
    // with the current secret, but the server allows use of the prior
    // secret as a one-time fallback when we've gone out of sync.
    static func lastClientSecret() -> String {
        if let prior = defaults.string(forKey: "whisper_last_client_secret") {
            return prior
        } else {
            let prior = makeSecret()
            defaults.setValue(prior, forKey: "whisper_last_client_secret")
            return prior
        }
    }
    static func clientSecret() -> String {
        if let current = defaults.string(forKey: "whisper_client_secret") {
            return current
        } else {
            let prior = lastClientSecret()
            defaults.setValue(prior, forKey: "whisper_client_secret")
            return prior
        }
    }
    static func updateClientSecret(_ secret: String) {
        // if the new secret is different than the old secret, save the old secret
        if let current = defaults.string(forKey: "whisper_client_secret"), secret != current {
            defaults.setValue(current, forKey: "whisper_last_client_secret")
        }
        defaults.setValue(secret, forKey: "whisper_client_secret")
    }
	static func resetClientSecret() {
		// apparently our secret has gone out of date with the server, so use the
		// one it knows about from us until we receive the new one.
		logger.warning("Resetting client secret to match server expectations")
		defaults.setValue(lastClientSecret(), forKey: "whisper_client_secret")
	}
	static func resetSecretsIfServerHasChanged() {
		// if we are operating against a different server than last run, we need
		// to reset our secrets as if this were the very first run, because our
		// current secret belongs to a different server.
		// NOTE: this needs to be run as early as possible in the launch sequence.
		guard let server = defaults.string(forKey: "whisper_last_used_server") else {
			// we've never launched before, so nothing to do except save the current server
			defaults.set(whisperServer, forKey: "whisper_last_used_server")
			return
		}
		guard server != whisperServer else {
			// still using the same server, nothing to do
			return
		}
		logger.warning("Server change noticed: resetting client secrets and conversation key")
		defaults.set(whisperServer, forKey: "whisper_last_used_server")
		defaults.removeObject(forKey: "whisper_last_client_secret")
		defaults.removeObject(forKey: "whisper_client_secret")
		defaults.removeObject(forKey: "content_channel_id")
	}
    static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result == errSecSuccess {
			return Data(bytes).base64EncodedString()
		} else {
			logAnomaly("Couldn't generate random bytes for secret, falling back to UUID")
			let fakeBytes = UUID().uuidString.replacingOccurrences(of: "-", with: "")
			return Data(fakeBytes.utf8).base64EncodedString()
		}
    }

	// scene state - one for each scene session, remembered so we can resume when reattached
	static private var sceneStates: [String: [String]] = {
		let saved = defaults.dictionary(forKey: "scene_state_map") as? [String: [String]]
		guard let saved = saved else {
			logger.debug("No saved sceneStates at startup")
			return [:]
		}
		logger.debug("\(saved.count) saved sceneStates at startup")
		return saved
	}()
	static private func saveSceneStates() {
		if sceneStates.isEmpty {
			logger.debug("There are no saved sceneStates")
			defaults.removeObject(forKey: "scene_state_map")
		} else {
			logger.debug("There are \(sceneStates.count) saved sceneStates")
			defaults.set(sceneStates, forKey: "scene_state_map")
		}
	}
	static func setSceneState(_ sceneId: String, mode: String, conversationId: String) {
		logger.debug("Setting scene state for scene \(sceneId) to (\(mode), \(conversationId))")
		sceneStates[sceneId] = [mode, conversationId]
		saveSceneStates()
	}
	static func clearSceneState(_ sceneId: String) {
		logger.debug("Clearing scene state for scene \(sceneId)")
		sceneStates.removeValue(forKey: sceneId)
		saveSceneStates()
	}
	static func getSceneState(_ sceneId: String) -> (mode: String, conversationId: String)? {
		guard let state = sceneStates[sceneId] else {
			logger.debug("No saved scene state for scene \(sceneId)")
			return nil
		}
		logger.debug("Saved scene state for scene \(sceneId) is (\(state[0]), \(state[1]))")
		return (mode: state[0], conversationId: state[1])
	}

	// content channel ID - one for each conversation, remembered so we can restart and rejoin
	static private var contentIds: [String: String] = {
		let saved = defaults.dictionary(forKey: "convo_content_id_map") as? [String: String]
		if saved == nil {
			logger.debug("No saved contentIds at startup")
			return [:]
		}
		logger.debug("\(saved!.count) saved contentIds at startup")
		return saved!
	}()
	static private func saveContentIds() {
		if contentIds.isEmpty {
			logger.debug("There are no saved contentIds")
			defaults.removeObject(forKey: "convo_content_id_map")
		} else {
			logger.debug("There are \(contentIds.count) saved contentIds")
			defaults.set(contentIds, forKey: "convo_content_id_map")
		}
	}
	static func clearContentId(_ conversationId: String) {
		logger.debug("Clearing content id for conversation \(conversationId)")
		contentIds.removeValue(forKey: conversationId)
		saveContentIds()
	}
	static func getContentId(_ conversationId: String) -> String {
		var id = contentIds[conversationId] ?? ""
		if id.isEmpty {
			logger.debug("Creating new content id for conversation \(conversationId)")
			id = UUID().uuidString
			contentIds[conversationId] = id
			saveContentIds()
		}
		logger.debug("Returning content id \(id) for conversation \(conversationId)")
		return id
	}

	// past text and live text: remembered so we can restart
	static private var textHistory: [String: [String]] = {
		guard let saved = defaults.dictionary(forKey: "text_history") as? [String: [String]] else {
			logger.debug("No saved textHistory entries at startup")
			return [:]
		}
		logger.debug("\(saved.count) saved textHistory entries at startup")
		return saved
	}()
	static private func saveTextHistory() {
		if textHistory.isEmpty {
			logger.debug("There are no saved textHistory entries")
			defaults.removeObject(forKey: "text_history")
		} else {
			logger.debug("There are \(textHistory.count) saved textHistory entries")
			defaults.set(textHistory, forKey: "text_history")
		}
	}
	static func setTextHistory(_ conversationId: String, past: String, live: String) {
		let summary = "past: \(past.count), live: \(live.count), ts: \(Date())"
		textHistory[conversationId] = [past, live, summary]
		logLifecycle("Text history summary saved for conversation \(conversationId): \(summary)")
		saveTextHistory()
	}
	static func clearTextHistory(_ conversationId: String) {
		textHistory.removeValue(forKey: conversationId)
		saveTextHistory()
	}
	static func getTextHistory(_ conversationId: String) -> (past: String, live: String)? {
		guard let entry = textHistory[conversationId] else {
			logger.debug("No textHistory for conversation \(conversationId)")
			return nil
		}
		let summary = entry.count > 2 ? entry[2] : "<no summary>"
		logLifecycle("Text history summary retrieved for conversation \(conversationId): \(summary)")
		return (past: entry[0], live: entry[1])
	}

	// size of text
	static var sizeWhenWhispering: FontSizes.FontSize {
		get {
			max(defaults.integer(forKey: "size_when_whispering_setting"), FontSizes.minTextSize)
		}
		set (new) {
			defaults.setValue(new, forKey: "size_when_whispering_setting")
		}
	}
	static var sizeWhenListening: FontSizes.FontSize {
		get {
			max(defaults.integer(forKey: "size_when_listening_setting"), FontSizes.minTextSize)
		}
		set (new) {
			defaults.setValue(new, forKey: "size_when_listening_setting")
		}
	}

	// whether to magnify text
	static var magnifyWhenWhispering: Bool {
		get {
			defaults.bool(forKey: "magnify_when_whispering_setting")
		}
		set (new) {
			defaults.setValue(new, forKey: "magnify_when_whispering_setting")
		}
	}
	static var magnifyWhenListening: Bool {
		get { 
			defaults.bool(forKey: "magnify_when_listening_setting")
		}
		set (new) {
			defaults.setValue(new, forKey: "magnify_when_listening_setting")
		}
	}

    // whether to speak past text
    static var speakWhenWhispering: Bool {
        get {
			defaults.bool(forKey: "speak_when_whispering_setting")
		}
        set (new) {
			defaults.setValue(new, forKey: "speak_when_whispering_setting")
		}
    }
    static var speakWhenListening: Bool {
        get {
			defaults.bool(forKey: "speak_when_listening_setting")
		}
        set (new) {
			defaults.setValue(new, forKey: "speak_when_listening_setting")
		}
    }

    // alert sounds
    struct AlertSoundChoice: Identifiable {
        var id: String
        var name: String
    }
    static let alertSoundChoices: [AlertSoundChoice] = [
        AlertSoundChoice(id: "air-horn", name: "Air Horn"),
        AlertSoundChoice(id: "bike-horn", name: "Bicycle Horn"),
        AlertSoundChoice(id: "bike-bell", name: "Bicycle Bell"),
    ]
    static var alertSound: String {
        get {
            return defaults.string(forKey: "alert_sound_setting") ?? "bike-horn"
        }
        set(new) {
            defaults.setValue(new, forKey: "alert_sound_setting")
        }
    }

	/// whether to show favorites while whispering
	static var showFavorites: Bool {
		get {
			defaults.bool(forKey: "show_favorites_setting")
		}
		set (new) {
			defaults.setValue(new, forKey: "show_favorites_setting")
		}
	}

	/// whether to hear typing while listening
	static var hearTyping: Bool {
		get {
			defaults.bool(forKey: "hear_typing_setting")
		}
		set (new) {
			defaults.setValue(new, forKey: "hear_typing_setting")
		}
	}

	/// typing sounds
	static let typingSoundChoices = [
		("a", "Old-fashioned Typewriter", "typewriter-two-minutes"),
		("b", "Modern Keyboard", "low-frequency-typing"),
	]
	static let typingSoundDefault = "typewriter-two-minutes"
	static var typingSound: String {
		get {
			let val = defaults.string(forKey: "typing_sound_choice_setting") ?? typingSoundDefault
			switch val {
			case "low-frequency-typing": return val
			default: return typingSoundDefault
			}
		}
		set(val) {
			for tuple in typingSoundChoices {
				if val == tuple.1 || val == tuple.2 {
					defaults.set(tuple.2, forKey: "typing_sound_choice_setting")
				}
			}
		}
	}
	static var typingVolume: Double {
		get {
			let diff = defaults.float(forKey: "typing_volume_setting")
			switch diff {
			case 0.25: return 0.25
			case 0.5: return 0.5
			default: return 1.0
			}
		}
		set(val) {
			var next: Double
			switch val {
			case 0.25: next = val
			case 0.5: next = val
			default: next = 1.0
			}
			defaults.setValue(next, forKey: "typing_volume_setting")
		}
	}

	/// the current favorites group
	static var currentFavoritesGroup: FavoritesGroup {
		get {
			if let name = defaults.string(forKey: "current_favorite_tag_setting"),
			   let group = UserProfile.shared.favoritesProfile.getGroup(name) {
				group
			} else {
				UserProfile.shared.favoritesProfile.allGroup
			}
		}
		set(new) {
			defaults.set(new.name, forKey: "current_favorite_tag_setting")
		}
	}

	/// Connection settings
	static var forceBluetooth: Bool {
		get {
			return defaults.bool(forKey: "force_bluetooth_setting")
		}
		set(val) {
			defaults.setValue(val, forKey: "force_bluetooth_setting")
		}
	}

	/// Preferences
	static private var whisperTapPreference: String {
		get {
			defaults.string(forKey: "whisper_tap_preference") ?? "show"
		}
		set(val) {
			defaults.setValue(val, forKey: "whisper_tap_preference")
		}
	}

	static var statusButtonsTopPreference: Bool {
		get {
			return defaults.bool(forKey: "status_buttons_top_preference")
		}
		set(val) {
			defaults.setValue(val, forKey: "status_buttons_top_preference")
		}
	}

	static var doServerSideTranscriptionPreference: Bool {
		get {
			return defaults.bool(forKey: "do_server_side_transcription_preference")
		}
		set(val) {
			defaults.setValue(val, forKey: "do_server_side_transcription_preference")
		}
	}

	static private var listenTapPreference: String {
		get {
			defaults.string(forKey: "listen_tap_preference") ?? "show"
		}
		set(val) {
			defaults.setValue(val, forKey: "listen_tap_preference")
		}
	}

	static private var newestWhisperLocationPreference: String {
		get {
			defaults.string(forKey: "newest_whisper_location_preference") ?? "bottom"
		}
		set(val) {
			defaults.setValue(val, forKey: "newest_whisper_location_preference")
		}
	}

	static private var elevenLabsApiKeyPreference: String {
		get {
			defaults.string(forKey: "elevenlabs_api_key_preference")?.trimmingCharacters(in: .whitespaces) ?? ""
		}
		set(val) {
			defaults.setValue(val.trimmingCharacters(in: .whitespaces), forKey: "elevenlabs_api_key_preference")
		}
	}

	static private var elevenLabsVoiceIdPreference: String {
		get {
			defaults.string(forKey: "elevenlabs_voice_id_preference")?.trimmingCharacters(in: .whitespaces) ?? ""
		}
		set(val) {
			defaults.setValue(val.trimmingCharacters(in: .whitespaces), forKey: "elevenlabs_voice_id_preference")
		}
	}

	static private var elevenLabsDictionaryIdPreference: String {
		get {
			defaults.string(forKey: "elevenlabs_dictionary_id_preference")?.trimmingCharacters(in: .whitespaces) ?? ""
		}
		set(val) {
			defaults.setValue(val.trimmingCharacters(in: .whitespaces), forKey: "elevenlabs_dictionary_id_preference")
		}
	}

	static private var elevenLabsDictionaryVersionPreference: String {
		get {
			defaults.string(forKey: "elevenlabs_dictionary_version_preference")?.trimmingCharacters(in: .whitespaces) ?? ""
		}
		set(val) {
			defaults.setValue(val.trimmingCharacters(in: .whitespaces), forKey: "elevenlabs_dictionary_version_preference")
		}
	}

	static private var elevenLabsLatencyReductionPreference: Int {
		get {
			defaults.integer(forKey: "elevenlabs_latency_reduction_preference") + 1
		}
		set(val) {
			defaults.setValue(val - 1, forKey: "elevenlabs_latency_reduction_preference")
		}
	}

	static private var interjectionPrefixPreference: String {
		get {
			defaults.string(forKey: "interjection_prefix_preference")?.trimmingCharacters(in: .whitespaces) ?? ""
		}
		set(val) {
			defaults.setValue(val.trimmingCharacters(in: .whitespaces), forKey: "interjection_prefix_preference")
		}
	}

	static private var interjectionAlertPreference: String {
		get {
			defaults.string(forKey: "interjection_alert_preference") ?? ""
		}
		set(val) {
			defaults.setValue(val, forKey: "interjection_alert_preference")
		}
	}

	static private var historyButtonsPreference: String {
		get {
			defaults.string(forKey: "history_buttons_preference") ?? "r-i-f"
		}
		set(val) {
			defaults.setValue(val, forKey: "history_buttons_preference")
		}
	}

	// behavior for Whisper tap
	static func whisperTapAction() -> String {
		return whisperTapPreference
	}

	// whether to request server-side transcription
	static func doServerSideTranscription() -> Bool {
		return doServerSideTranscriptionPreference
	}

	// behavior for Listen tap
	static func listenTapAction() -> String {
		return defaults.string(forKey: "listen_tap_preference") ?? "show"
	}

	// layout control of listeners
	static func listenerMatchesWhisperer() -> Bool {
		return newestWhisperLocationPreference == "bottom"
	}

	// speech keys
	static func elevenLabsApiKey() -> String {
		return elevenLabsApiKeyPreference
	}
	static func elevenLabsVoiceId() -> String {
		return elevenLabsVoiceIdPreference
	}
	static func elevenLabsDictionaryId() -> String {
		return elevenLabsDictionaryIdPreference
	}
	static func elevenLabsDictionaryVersion() -> String {
		return elevenLabsDictionaryVersionPreference
	}
	static func elevenLabsLatencyReduction() -> Int {
		return elevenLabsLatencyReductionPreference
	}

	// interjection behavior
	static func interjectionPrefix() -> String {
		if interjectionPrefixPreference.isEmpty {
			return ""
		} else {
			return interjectionPrefixPreference + " "
		}
	}

	static func interjectionAlertSound() -> String {
		return interjectionAlertPreference
	}

	// server-side logging
	static var doPresenceLogging: Bool {
		get {
			return !defaults.bool(forKey: "do_not_log_to_server_setting")
		}
		set (val) {
			defaults.setValue(!val, forKey: "do_not_log_to_server_setting")
		}
	}

	static let preferenceVersion = 5

	static func preferencesToJson() -> String {
		let preferences = [
			"version": "\(preferenceVersion)",
			"whisper_tap_preference": whisperTapPreference,
			"status_buttons_top_preference": statusButtonsTopPreference ? "yes" : "no",
			"do_server_side_transcription_preference": doServerSideTranscriptionPreference ? "yes" : "no",
			"listen_tap_preference": listenTapPreference,
			"newest_whisper_location_preference": newestWhisperLocationPreference,
			"elevenlabs_api_key_preference": elevenLabsApiKeyPreference,
			"elevenlabs_voice_id_preference": elevenLabsVoiceIdPreference,
			"elevenlabs_dictionary_id_preference": elevenLabsDictionaryIdPreference,
			"elevenlabs_dictionary_version_preference": elevenLabsDictionaryVersionPreference,
			"elevenlabs_latency_reduction_preference": "\(elevenLabsLatencyReductionPreference)",
			"interjection_prefix_preference": interjectionPrefixPreference,
			"interjection_alert_preference": interjectionAlertPreference,
			"history_buttons_preference": historyButtonsPreference,
		]
		guard let json = try? JSONSerialization.data(withJSONObject: preferences, options: .sortedKeys) else {
			fatalError("Can't encode preferences data: \(preferences)")
		}
		return String(decoding: json, as: UTF8.self)
	}

	static func jsonToPreferences(_ json: String) {
		guard let val = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
			  let preferences = val as? [String: String]
		else {
			fatalError("Can't decode preferences data: \(json)")
		}
		let version = Int(preferences["version"] ?? "") ?? 1
		if version != preferenceVersion {
			logAnomaly("Setting preferences from v\(version) preference data, expected v\(preferenceVersion)")
		}
		whisperTapPreference = preferences["whisper_tap_preference"] ?? "show"
		statusButtonsTopPreference = preferences["status_buttons_top_preference"] ?? "no" == "yes"
		doServerSideTranscriptionPreference = preferences["do_server_side_transcription_preference"] ?? "no" == "yes"
		listenTapPreference = preferences["listen_tap_preference"] ?? "show"
		newestWhisperLocationPreference = preferences["newest_whisper_location_preference"] ?? "bottom"
		elevenLabsApiKeyPreference = preferences["elevenlabs_api_key_preference"] ?? ""
		elevenLabsVoiceIdPreference = preferences["elevenlabs_voice_id_preference"] ?? ""
		elevenLabsDictionaryIdPreference = preferences["elevenlabs_dictionary_id_preference"] ?? ""
		elevenLabsDictionaryVersionPreference = preferences["elevenlabs_dictionary_version_preference"] ?? ""
		elevenLabsLatencyReductionPreference = Int(preferences["elevenlabs_latency_reduction_preference"] ?? "") ?? 1
		interjectionPrefixPreference = preferences["interjection_prefix_preference"] ?? ""
		interjectionAlertPreference = preferences["interjection_alert_preference"] ?? ""
		historyButtonsPreference = preferences["history_buttons_preference"] ?? "r-i-f"
	}
}
