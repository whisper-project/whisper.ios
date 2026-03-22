// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation

/// The original point of this protocol was to incrementally send user-entered live text from
/// the whisperer to the listeners.  That's still a goal, but it has been enhanced to handle
/// invites, conversation IDs, and communication controls between whisperer and listener.
/// See the design docs for more detail.
final class WhisperProtocol {
    enum ControlOffset: Int, CustomStringConvertible {
        /// content control messages
        case newline = -1           // Shift current live text to past text (no packet data)
        case pastText = -2          // Add single line of past text given by packet data
        case liveText = -3          // Replace current live text with packet data
        case startReread = -4       // Start sending re-read.  Packet data is `ReadType` being sent.
        case clearHistory = -6      // Tell Listener to clear their history.
        case playSound = -7         // Play the sound named by the packet data.
        case playSpeech = -8        // Generate speech for the packet data.

        /// handshake control (aka "presence") messages - packet data for all these is the [ClientInfo]
        case whisperOffer = -20     // Whisperer offers a conversation to listener
        case listenRequest = -21    // Listener requests to join a conversation
        case listenAuthYes = -22    // Whisperer authorizes Listener to join a conversation.
        case listenAuthNo = -23     // Whisperer doesn't authorize Listener to join a conversation.
        case joining = -24          // An allowed listener is joining the conversation.
        case dropping = -25         // A whisperer or listener is dropping from the conversation.
        case listenOffer = -26      // A Listener is looking to rejoin a conversation: only client ID and profile ID are included.
		case restart = -27			// A Whisperer has had to restart, so all Listeners must as well (like drop but with reconnect)

		/// flow control messages
		case requestReread = -40    // Request re-read. Packet data is `ReadType` of request.

		/// general messages
		case shareTranscript = -50	// Share the transcript ID with the listeners

        var description: String {
            switch self {
            case .newline:
                return "newline"
            case .pastText:
                return "past text"
            case .liveText:
                return "live text"
            case .startReread:
                return "start reread"
            case .requestReread:
                return "request reread"
            case .clearHistory:
                return "clear history"
            case .playSound:
                return "play sound"
            case .playSpeech:
                return "play speech"
            case .whisperOffer:
                return "whisper offer"
            case .listenRequest:
                return "listen request"
            case .listenAuthYes:
                return "listen authorization"
            case .listenAuthNo:
                return "listen deauthorization"
            case .joining:
                return "joining conversation"
            case .dropping:
                return "leaving conversation"
            case .listenOffer:
                return "listen offer"
			case .restart:
				return "leaving and rejoining conversation"
			case .shareTranscript:
				return "sharing transcript id"
            }
        }
    }
    
    /// Reads allow the whisperer to update a listener which is out of sync.
    /// Each read sequence has a "type" indicating which text it's reading.
    enum ReadType: String {
        case live = "live"
        case past = "past"
        case all = "all"
    }
    
    /// Client info as passed in the packet data of invites
    struct ClientInfo {
        var conversationId: String
        var conversationName: String
        var clientId: String
        var profileId: String
        var username: String
        var contentId: String
        
        func toString() -> String {
            return "\(conversationId)|\(conversationName)|\(clientId)|\(profileId)|\(username)|\(contentId)"
        }
        
        static func fromString(_ s: String) -> ClientInfo? {
            let parts = s.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count != 6 {
				logAnomaly("Malformed TextProtocol.ClientInfo data: \(s)")
                return nil
            }
            return ClientInfo(conversationId: String(parts[0]),
                              conversationName: String(parts[1]),
                              clientId: String(parts[2]),
                              profileId: String(parts[3]),
                              username: String(parts[4]),
                              contentId: String(parts[5]))
        }
    }
    
	struct ProtocolChunk: CustomStringConvertible {
        var offset: Int
        var text: String
        
		var description: String {
			if self.offset >= 0 {
				return self.toString()
			} else {
				let offset = ControlOffset(rawValue: self.offset)?.description ?? "Unknown (\(self.offset))"
				return "\(offset) control message: \(self.text)"
			}
		}

        func toString() -> String {
            return "\(offset)|" + text
        }
        
        func toData() -> Data {
            return Data(self.toString().utf8)
        }
        
        static func fromString(_ s: String) -> ProtocolChunk? {
            let parts = s.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count != 2 {
                // data packets with no "|" character are malformed
				logAnomaly("Malformed TextProtocol.ProtocolChunk data: \(s)", kind: .global)
                return nil
            } else if let offset = Int(parts[0]) {
                return ProtocolChunk(offset: offset, text: String(parts[1]))
            } else {
                // data packets with no int before the "|" are malformed
				logAnomaly("Malformed TextProtocol.ProtocolChunk data: \(s)")
                return nil
            }
        }
        
        static func fromData(_ data: Data) -> ProtocolChunk? {
            return fromString(String(decoding: data, as: UTF8.self))
        }
        
        /// a "diff" packet is one that incrementally affects live text
        func isDiff() -> Bool {
            offset >= ControlOffset.newline.rawValue
        }
        
        func isCompleteLine() -> Bool {
            return offset == ControlOffset.newline.rawValue || offset == ControlOffset.pastText.rawValue
        }
        
        func isLastRead() -> Bool {
            return offset == ControlOffset.liveText.rawValue
        }
        
        func isFirstRead() -> Bool {
            return offset == ControlOffset.startReread.rawValue
        }
        
        func isSound() -> Bool {
            return offset == ControlOffset.playSound.rawValue
        }
        
        func isReplayRequest() -> Bool {
            return offset == ControlOffset.requestReread.rawValue
        }
        
        func isPresenceMessage() -> Bool {
            return (offset <= ControlOffset.whisperOffer.rawValue &&
                    offset >= ControlOffset.restart.rawValue)
        }
        
        func isListenOffer() -> Bool {
            return offset == ControlOffset.listenOffer.rawValue
        }

		func isRestart() -> Bool {
			return offset == ControlOffset.restart.rawValue
		}

		func isTranscriptId() -> Bool {
			return offset == ControlOffset.shareTranscript.rawValue
		}

        static func fromPastText(text: String) -> ProtocolChunk {
            return ProtocolChunk(offset: ControlOffset.pastText.rawValue, text: text)
        }
        
        static func fromLiveText(text: String) -> ProtocolChunk {
            return ProtocolChunk(offset: ControlOffset.liveText.rawValue, text: text)
        }
        
        static func acknowledgeRead(hint: ReadType) -> ProtocolChunk {
            return ProtocolChunk(offset: ControlOffset.startReread.rawValue, text: hint.rawValue)
        }
        
        static func sound(_ text: String) -> ProtocolChunk {
            return ProtocolChunk(offset: ControlOffset.playSound.rawValue, text: text)
        }
        
        static func replayRequest(hint: ReadType) -> ProtocolChunk {
            return ProtocolChunk(offset: ControlOffset.requestReread.rawValue, text: hint.rawValue)
        }
        
		private static func authChunk(offset: Int, c: any Conversation, contentId: String = "") -> ProtocolChunk {
            let profile = UserProfile.shared
            let data = ClientInfo(conversationId: c.id,
                                  conversationName: c.name,
                                  clientId: PreferenceData.clientId,
                                  profileId: profile.id,
                                  username: profile.username,
                                  contentId: contentId)
            return ProtocolChunk(offset: offset, text: data.toString())
        }
        
		static func whisperOffer(_ c: any Conversation) -> ProtocolChunk {
            return authChunk(offset: ControlOffset.whisperOffer.rawValue, c: c)
        }
        
		static func listenRequest(_ c: any Conversation) -> ProtocolChunk {
            return authChunk(offset: ControlOffset.listenRequest.rawValue, c: c)
        }
        
		static func listenAuthYes(_ c: any Conversation, contentId: String = "") -> ProtocolChunk {
            return authChunk(offset: ControlOffset.listenAuthYes.rawValue, c: c, contentId: contentId)
        }
        
		static func listenAuthNo(_ c: any Conversation) -> ProtocolChunk {
            return authChunk(offset: ControlOffset.listenAuthNo.rawValue, c: c)
        }
        
		static func joining(_ c: any Conversation) -> ProtocolChunk {
            return authChunk(offset: ControlOffset.joining.rawValue, c: c)
        }
        
        static func dropping() -> ProtocolChunk {
			let info = ClientInfo(conversationId: "",
								  conversationName: "",
								  clientId: PreferenceData.clientId,
								  profileId: "",
								  username: "",
								  contentId: "")
			return ProtocolChunk(offset: ControlOffset.dropping.rawValue, text: info.toString())
        }
        
		static func listenOffer(_ c: any Conversation) -> ProtocolChunk {
			let info = ClientInfo(conversationId: c.id,
								  conversationName: c.name,
                                  clientId: PreferenceData.clientId,
                                  profileId: UserProfile.shared.id,
                                  username: "",
                                  contentId: "")
            return ProtocolChunk(offset: ControlOffset.listenOffer.rawValue, text: info.toString())
        }

		static func restart() -> ProtocolChunk {
			let info = ClientInfo(conversationId: "",
								  conversationName: "",
								  clientId: PreferenceData.clientId,
								  profileId: "",
								  username: "",
								  contentId: "")
			return ProtocolChunk(offset: ControlOffset.restart.rawValue, text: info.toString())
		}

		static func shareTranscript(id: String) -> ProtocolChunk {
			return ProtocolChunk(offset: ControlOffset.shareTranscript.rawValue, text: id)
		}

        static func fromLiveTyping(text: String, start: Int) -> [ProtocolChunk] {
            guard text.count > start else {
                return []
            }
            let lines = text.suffix(text.count - start).split(separator: "\n", omittingEmptySubsequences: false)
            var result: [ProtocolChunk] = [ProtocolChunk(offset: start, text: String(lines[0]))]
            for line in lines.dropFirst() {
                result.append(ProtocolChunk(offset: ControlOffset.newline.rawValue, text: ""))
                result.append(ProtocolChunk(offset: 0, text: String(line)))
            }
            return result
        }
    }
    
    /// Create a series of incremental protocol chunks that will turn the old typing into the new typing.
    /// The old typing is assumed not to have any newlines in it.  The new typing may have
    /// newlines in it, in which case there will be multiple chunks in the output with an
    /// incremental complete line chunk for every newline.
    static func diffLines(old: String, new: String) -> [ProtocolChunk] {
        let matching = zip(old.indices, new.indices)
        for (i, j) in matching {
            if old[i] != new[j] {
                return ProtocolChunk.fromLiveTyping(text: new, start: old.distance(from: old.startIndex, to: i))
            }
        }
        // if we fall through, one is a substring of the other
        if old.count == new.count {
            // no changes
            return []
        } else if old.count < new.count {
            return ProtocolChunk.fromLiveTyping(text: new, start: old.count)
        } else {
            // new is a prefix of old
            return [ProtocolChunk(offset: new.count, text: "")]
        }
    }
    
    /// Apply a single, incremental text chunk to the old typing (which has no newlines).
    static func applyDiff(old: String, chunk: ProtocolChunk) -> String {
        let prefix = String(old.prefix(chunk.offset))
        return prefix + chunk.text
    }
}

func logControlChunk(sentOrReceived: String, chunk: WhisperProtocol.ProtocolChunk, kind: TransportKind = .global) {
	logger.info("\(sentOrReceived, privacy: .public) \(kind, privacy: .public) control chunk: \(chunk, privacy: .public)")
	guard kind == .local || PreferenceData.doPresenceLogging else {
		// we always log Bluetooth presence packets, because the server doesn't see them
		return
	}
	guard chunk.isPresenceMessage() else {
		return
	}
	let path = "/api/v2/logPresenceChunk"
	guard let url = URL(string: PreferenceData.whisperServer + path) else {
		fatalError("Can't create URL for presence packet logging")
	}
	func handler(status: Int, data: Data) -> Void {
		if status != 204 {
			logger.error("\(status) response turns off packet logging")
			PreferenceData.doPresenceLogging = false
		}
	}
	var request = URLRequest(url: url)
	let localValue = [
		"clientId": PreferenceData.clientId,
		"kind": kind == .global ? "TCP" : "Bluetooth",
		"sentOrReceived": sentOrReceived,
		"chunk": chunk.toString()
	]
	guard let localData = try? JSONSerialization.data(withJSONObject: localValue) else {
		fatalError("Can't encode presence chunk data: \(localValue)")
	}
	request.httpMethod = "POST"
	request.setValue("application/json", forHTTPHeaderField: "Content-Type")
	request.httpBody = localData
	Data.executeJSONRequest(request, handler: handler)
}

@discardableResult func logLifecycle(_ message: String) -> URLSessionDataTask {
	logger.info("Lifecycle event reported: \(message, privacy: .public)")
	return sendClientLogMessage(message, type: "Lifecycle", level: "info")
}

func logAnomaly(_ message: String, kind: TransportKind? = nil) {
	let kindString = kind == nil ? "Runtime" : kind == .global ? "TCP" : "Bluetooth"
	logger.error("\(kindString, privacy: .public) anomaly reported: \(message, privacy: .public)")
	sendClientLogMessage(message, type: kindString, level: "error")
}

@discardableResult func sendClientLogMessage(_ message: String, type: String, level: String) -> URLSessionDataTask {
	let path = "/api/v2/logAnomaly"
	guard let url = URL(string: PreferenceData.whisperServer + path) else {
		fatalError("Can't create URL for anomaly logging")
	}
	var request = URLRequest(url: url)
	let localValue = [
		"clientId": PreferenceData.clientId,
		"kind": type,
		"level": level,
		"message": message
	]
	guard let localData = try? JSONSerialization.data(withJSONObject: localValue) else {
		fatalError("Can't encode anomaly data: \(localValue)")
	}
	request.httpMethod = "POST"
	request.setValue("application/json", forHTTPHeaderField: "Content-Type")
	request.httpBody = localData
	return Data.executeJSONRequest(request)
}

func logChannelEvent(_ info: [String: String]) {
	var info = info
	info["clientId"] = PreferenceData.clientId
	logger.info("Channel event: \(info)")
	let path = "/api/v2/logChannelEvent"
	guard let url = URL(string: PreferenceData.whisperServer + path) else {
		fatalError("Can't create URL for channel event logging")
	}
	var request = URLRequest(url: url)
	guard let data = try? JSONSerialization.data(withJSONObject: info) else {
		fatalError("Can't encode event data: \(info)")
	}
	request.httpMethod = "POST"
	request.setValue("application/json", forHTTPHeaderField: "Content-Type")
	request.httpBody = data
	Data.executeJSONRequest(request)
}
