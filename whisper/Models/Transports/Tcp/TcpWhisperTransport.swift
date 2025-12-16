// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import Combine
import Ably

final class TcpWhisperTransport: PublishTransport {
    // MARK: protocol properties and methods
    typealias Remote = Listener
    
    var lostRemoteSubject: PassthroughSubject<Remote, Never> = .init()
    var contentSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()
    var controlSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()

    func start(failureCallback: @escaping TransportErrorCallback) {
        logger.log("Starting TCP whisper transport")
        self.failureCallback = failureCallback
		self.authenticator = TcpAuthenticator(mode: .whisper,
											  conversationId: conversation.id,
											  conversationName: conversation.name,
											  callback: receiveAuthError)
        openChannels()
    }
    
    func stop() {
        logger.log("Stopping TCP whisper Transport")
        closeChannels()
    }
    
    func goToBackground() {
    }
    
    func goToForeground() {
    }
    
    func sendControl(remote: Remote, chunk: WhisperProtocol.ProtocolChunk) {
        guard let remote = remotes[remote.id] else {
            logAnomaly("Ignoring request to send chunk to an unknown remote: \(remote.id)", kind: .global)
            return
        }
		sendControlInternal(id: remote.id, data: chunk)
    }

    func drop(remote: Remote) {
        guard let remote = remotes[remote.id] else {
			logAnomaly("Ignoring request to drop unknown remote: \(remote.id)", kind: remote.kind)
			return
        }
        logger.info("Dropping \(remote.kind) remote \(remote.id)")
		removeRemote(remote)
    }

	func authorize(remote: Listener) {
		remote.isAuthorized = true
	}

	func deauthorize(remote: Listener) {
		remote.isAuthorized = false
	}

	func sendContent(remote: Remote, chunks: [WhisperProtocol.ProtocolChunk]) {
		guard let remote = remotes[remote.id] else {
			logAnomaly("Ignoring request to send chunk to an unknown remote: \(remote.id)", kind: .global)
			return
		}
		for chunk in chunks {
			contentChannel?.publish(remote.id, data: chunk.toString(), callback: receiveErrorInfo)
		}
	}

    func publish(chunks: [WhisperProtocol.ProtocolChunk]) {
		// we always publish because the server is always listening
        for chunk in chunks {
            contentChannel?.publish("all", data: chunk.toString(), callback: receiveErrorInfo)
        }
    }

	// eternal non-protocol method
	func getTranscriptId() -> String? {
		authenticator?.getTranscriptId()
	}

    // MARK: Internal types, properties, and initialization
    final class Listener: TransportRemote {
        let id: String
		let kind: TransportKind = .global

		fileprivate var isAuthorized: Bool = false
		fileprivate var hasDropped: Bool = false

		init(id: String) {
            self.id = id
        }
    }
    
    private var failureCallback: TransportErrorCallback?
    private var clientId: String
    private var conversation: WhisperConversation
    private var authenticator: TcpAuthenticator!
    private var client: ARTRealtime?
    private var contentChannel: ARTRealtimeChannel?
    private var controlChannel: ARTRealtimeChannel?
    private var remotes: [String:Remote] = [:]

    init(_ c: WhisperConversation) {
        self.clientId = PreferenceData.clientId
        self.conversation = c
    }
    
    //MARK: Internal methods
    private func receiveErrorInfo(_ error: ARTErrorInfo?) {
        if let error = error {
			logAnomaly("Whisper send/receive error: \(error.message)", kind: .global)
        }
    }
    
	private func receiveAuthError(_ severity: TransportErrorSeverity, _ reason: String) {
		logAnomaly("Whisper authentication error: \(reason)", kind: .global)
        failureCallback?(severity, reason)
        closeChannels()
    }
    
    private func openChannels() {
        client = self.authenticator.getClient()
        client!.connection.on(.connected) { _ in
            logger.log("TCP whisper transport realtime client has connected")
        }
        client!.connection.on(.disconnected) { _ in
            logger.log("TCP whisper transport realtime client has disconnected")
        }
		openContentChannel()
        openControlChannel()
    }

	private func openContentChannel() {
		let channel = client!.channels.get(conversation.id + ":" + PreferenceData.getContentId(conversation.id))
		contentChannel = channel
	}

	private func openControlChannel() {
		let channel = client!.channels.get(conversation.id + ":control")
		controlChannel = channel
		channel.on(monitorControlChannelState)
		channel.once(ARTChannelEvent.attached) { _ in
			let chunk = WhisperProtocol.ProtocolChunk.whisperOffer(self.conversation)
			self.sendControlInternal(id: "all", data: chunk)
		}
		channel.subscribe(receiveControlMessage)
		channel.presence.subscribe(receivePresenceMessage)
		channel.presence.enter("whisperer")
	}

	private func monitorControlChannelState(_ change: ARTChannelStateChange) {
		var event = "none"
		var resumed = ""
		var errCode = ""
		var errMessage = ""
		switch change.event {
		case .attached:
			event = "attached"
			resumed = "\(change.resumed)"
		case .suspended:
			event = "suspended"
		case .failed:
			event = "failed"
			if let code = change.reason?.code {
				errCode = "\(code)"
			}
			if let message = change.reason?.message {
				errMessage = message
			}
		case .update:
			event = "update"
			resumed = "\(change.resumed)"
		default:
			return
		}
		logChannelEvent(["participant": "Whisperer",
		                 "conversationId": conversation.id,
		                 "channelId": "control",
		                 "event": event,
		                 "resumed": resumed,
		                 "errCode": errCode,
		                 "errMessage": errMessage])
	}

    private func closeChannels() {
		guard let control = controlChannel else {
			// we never opened the channels, so nothing to do
			return
		}
		logger.info("Send drop message to \(self.remotes.count) remotes")
        let chunk = WhisperProtocol.ProtocolChunk.dropping()
        control.publish("all", data: chunk.toString(), callback: receiveErrorInfo)
		contentChannel = nil
		control.presence.leave("whisperer")
        control.detach()
        controlChannel = nil
		client = nil
		authenticator.releaseClient()
    }
    
	private func sendControlInternal(id: String, data: WhisperProtocol.ProtocolChunk) {
		logControlChunk(sentOrReceived: "sent", chunk: data)
		controlChannel?.publish(id, data: data.toString(), callback: receiveErrorInfo)
	}

	private func receiveControlMessage(message: ARTMessage) {
		let topic = message.name ?? "unknown"
		guard topic == "whisperer" || topic == PreferenceData.clientId else {
			logger.debug("Ignoring control message meant for \(topic, privacy: .public): \(String(describing: message.data), privacy: .public)")
			return
		}
		guard let remote = listenerFor(message.clientId) else {
			logAnomaly("Ignoring a message with a missing client id: \(message)", kind: .global)
			return
		}
        guard let payload = message.data as? String,
              let chunk = WhisperProtocol.ProtocolChunk.fromString(payload)
        else {
			logAnomaly("Ignoring a message with a non-chunk payload: \(String(describing: message))", kind: .global)
            return
        }
		logControlChunk(sentOrReceived: "received", chunk: chunk)
		if chunk.offset == WhisperProtocol.ControlOffset.dropping.rawValue {
			logger.info("Received dropping message from \(remote.kind) remote \(remote.id)")
			remote.hasDropped = true
			removeRemote(remote)
			lostRemoteSubject.send(remote)
			return
		}
		logger.notice("Received control packet from \(remote.kind, privacy: .public) remote \(remote.id, privacy: .public): \(chunk, privacy: .public)")
        controlSubject.send((remote: remote, chunk: chunk))
    }

	private func receivePresenceMessage(message: ARTPresenceMessage) {
		// look out for web remotes which detach by closing their window
		// (in which case no drop messages are sent)
		guard message.action == .leave || message.action == .absent else {
			return
		}
		guard let clientId = message.clientId, clientId != PreferenceData.clientId else {
			// ignore messages from ourself
			return
		}
		guard let remote = remotes[clientId] else {
			// ignore messages from clients we're not connected to
			logAnomaly("Got a presence message from a client that's not a listening remote?")
			return
		}
		guard !remote.hasDropped else {
			logger.info("Received leave presence message from an already-dropped remote")
			return
		}
		logger.info("Got leave message from a remote which hasn't dropped: \(remote.id)")
		remote.hasDropped = true
		removeRemote(remote)
		lostRemoteSubject.send(remote)
	}

	private func removeRemote(_ remote: Remote) {
		if !remote.hasDropped {
			// tell this remote we're dropping it
			let chunk = WhisperProtocol.ProtocolChunk.dropping()
			sendControl(remote: remote, chunk: chunk)
		}
		remotes.removeValue(forKey: remote.id)
	}

	private func listenerFor(_ clientId: String?) -> Remote? {
		guard let clientId = clientId else {
			return nil
		}
		if let existing = remotes[clientId] {
			return existing
		}
		let remote = Listener(id: clientId)
		remotes[clientId] = remote
		return remote
	}
}
