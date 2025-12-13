// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import AVFAudio
import Combine
import CoreBluetooth
import UserNotifications

final class ListenViewModel: ObservableObject {
    typealias Remote = ComboFactory.Subscriber.Remote
    typealias Transport = ComboFactory.Subscriber

	final class Candidate: Identifiable, Comparable {
		private(set) var id: String
		private(set) var remote: Remote
		private(set) var info: WhisperProtocol.ClientInfo
		var isPending: Bool
		private(set) var created: Date

		init(remote: Remote, info: WhisperProtocol.ClientInfo, isPending: Bool) {
			self.id = remote.id
			self.remote = remote
			self.info = info
			self.isPending = isPending
			self.created = Date.now
		}

		// compare by network and creation date
		static func == (lhs: ListenViewModel.Candidate, rhs: ListenViewModel.Candidate) -> Bool {
			return lhs.remote.kind == rhs.remote.kind && lhs.created == rhs.created
		}

		// sort by network, then oldest first
		static func < (lhs: ListenViewModel.Candidate, rhs: ListenViewModel.Candidate) -> Bool {
			if lhs.remote.kind == rhs.remote.kind {
				return lhs.created > rhs.created
			} else {
				return lhs.remote.kind == .local
			}
		}
	}

    @Published var statusText: String = ""
    @Published var liveText: String = ""
	@Published var conversationEnded: Bool = false
	@Published var conversationRestarted: Bool = false
    @Published var connectionError: Bool = false
	@Published var connectionErrorSeverity: TransportErrorSeverity = .report
    @Published var connectionErrorDescription: String = ""
    @Published var showStatusDetail: Bool = false
	@Published var candidates: [String: Candidate] = [:]	// remoteId -> Candidate
	@Published var invites: [Candidate] = []
	@Published var conversation: ListenConversation
	@Published var conversationName: String
    @Published var whisperer: Candidate?
    @Published var pastText: PastTextModel = .init(mode: .listen)
	@Published var transcriptId: String? = nil

    private var transport: Transport
    private var cancellables: Set<AnyCancellable> = []
	private var clients: [String: Candidate] = [:]	// clientId -> Candidate, for avoiding dups
	private var pendingWhisperer: Candidate? = nil
    private var discoveryInProgress = false
    private var discoveryCountDown = 0
    private var discoveryTimer: Timer?
    private var resetInProgress = false
    private var isFirstConnect = true
    private var isInBackground = false
    private var soundEffect: AVAudioPlayer?
	private var typingPlayer: AVAudioPlayer?
    private var notifySoundInBackground = false

	let profile = UserProfile.shared.listenProfile

	init(_ conversation: ListenConversation) {
		logger.log("Initializing ListenView model")
		self.conversation = conversation
		self.conversationName = conversation.name
        transport = ComboFactory.shared.subscriber(conversation)
        transport.lostRemoteSubject
            .sink{ [weak self] in self?.dropCandidate($0) }
            .store(in: &cancellables)
		transport.contentSubject
			.sink{ [weak self] in self?.receiveContentChunk($0) }
			.store(in: &cancellables)
		transport.controlSubject
			.sink{ [weak self] in self?.receiveControlChunk($0) }
			.store(in: &cancellables)
    }
    
    deinit {
		logger.log("Destroying ListenView model")
        cancellables.cancel()
    }
    
    // MARK: View entry points
    func start() {
		logger.info("Starting listen session")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if error != nil {
                logger.error("Error asking the user to approve alerts: \(error!, privacy: .public)")
            }
            self.notifySoundInBackground = granted
        }
        resetTextForConnection()
		awaitDiscovery()
        refreshStatusText()
        transport.start(failureCallback: signalConnectionError)
    }
    
    func stop() {
		logger.info("Stopping listen session")
		stopTypingSound()
		transport.stop()
		whisperer = nil
		invites.removeAll()
		candidates.removeAll()
		clients.removeAll()
		cancelDiscovery()
        statusText = "Stopped Listening"
    }
    
    func wentToBackground() {
        guard !isInBackground else {
            return
        }
        isInBackground = true
		stopTypingSound()
        transport.goToBackground()
    }
    
    func wentToForeground() {
        guard isInBackground else {
            return
        }
        isInBackground = false
        transport.goToForeground()
        // after going to background, assume not waiting any more
		if discoveryTimer != nil {
			logger.log("End initial wait for whisperers due to background transition")
			cancelDiscovery()
		}
    }

	func acceptInvite(_ id: String) {
		guard let inviter = candidates[id] else {
			logAnomaly("Shouldn't happen: accepting non-invite \(id)")
			return
		}
		logger.info("Accepted invite from \(inviter.remote.kind) remote \(inviter.id) conversation \(inviter.info.conversationName)")
		inviter.isPending = false
		pendingWhisperer = inviter
		let conversation = profile.forInvite(info: inviter.info)
		conversationName = conversation.name
		let chunk = WhisperProtocol.ProtocolChunk.listenRequest(conversation)
		transport.sendControl(remote: inviter.remote, chunk: chunk)
		refreshStatusText()
	}

	func refuseInvite(_ id: String) {
		guard let inviter = candidates.removeValue(forKey: id) else {
			logAnomaly("Shouldn't happen: rejecting a non-invite: \(id)")
			return
		}
		logger.info("Rejected invite from \(inviter.remote.kind) remote \(inviter.id) conversation \(inviter.info.conversationName)")
		clients.removeValue(forKey: inviter.info.clientId)
		transport.drop(remote: inviter.remote)
		refreshStatusText()
	}

    // re-read the whispered text
    func readLiveText() {
        guard let whisperer = whisperer else {
			logAnomaly("Shouldn't happen: can't read live text with no Whisperer")
			return
        }
        guard !resetInProgress else {
            logger.log("Got reset during reset, ignoring it")
            return
        }
        logger.log("Requesting re-read of live text")
        resetInProgress = true
        let chunk = WhisperProtocol.ProtocolChunk.replayRequest(hint: WhisperProtocol.ReadType.live)
		transport.sendControl(remote: whisperer.remote, chunk: chunk)
    }
    
    // MARK: Transport subscription handlers
    private func dropCandidate(_ remote: Remote) {
		guard let removed = candidates.removeValue(forKey: remote.id) else {
			logger.info("Ignoring dropped \(remote.kind) non-candidate \(remote.id)")
            return
        }
		clients.removeValue(forKey: removed.info.clientId)
        if removed === whisperer {
            logger.info("Dropped the \(remote.kind) whisperer \(removed.id)")
            whisperer = nil
            // we have lost the whisperer
            resetTextForConnection()
            refreshStatusText()
			conversationEnded = true
        } else {
            logger.info("Dropped \(remote.kind) candidate \(removed.id)")
        }
    }
    
    private func receiveContentChunk(_ pair: (remote: Remote, chunk: WhisperProtocol.ProtocolChunk)) {
		guard pair.remote.id == whisperer?.id else {
            logAnomaly("Shouldn't happen: Received content from non-whisperer \(pair.remote.id)")
			return
        }
        processContentChunk(pair.chunk)
    }
        
	private func receiveControlChunk(_ pair: (remote: Remote, chunk: WhisperProtocol.ProtocolChunk)) {
		processControlChunk(remote: pair.remote, chunk: pair.chunk)
	}

    // MARK: internal helpers
    private func resetTextForConnection() {
		liveText = connectingLiveText
        if isFirstConnect {
            pastText.setFromText(connectingPastText)
        }
    }
    
	private func signalConnectionError(_ severity: TransportErrorSeverity, _ reason: String) {
        Task { @MainActor in
            connectionError = true
			connectionErrorSeverity = severity
            connectionErrorDescription = reason
        }
    }
    
    private func processContentChunk(_ chunk: WhisperProtocol.ProtocolChunk) {
        if chunk.isSound() {
            logger.log("Received request to play sound '\(chunk.text)'")
            playSound(chunk.text)
		} else if chunk.isDiff() {
			// Whisperers don't send diffs during replay, so maybe we missed the terminator
			resetInProgress = false
			if chunk.offset == 0 {
				if liveText.isEmpty && !chunk.text.isEmpty {
					maybeStartTypingSound()
				} else if !liveText.isEmpty && chunk.text.isEmpty {
					stopTypingSound()
				}
				liveText = chunk.text
			} else if chunk.isCompleteLine() {
				if !isInBackground && PreferenceData.speakWhenListening {
					speak(liveText)
				}
				maybeEndTypingSound()
				pastText.addLine(liveText)
				liveText = ""
			} else if chunk.offset > liveText.count {
				// we must have missed a packet, read the full state to reset
				logAnomaly("Resetting live text after missed packet...", kind: whisperer!.remote.kind)
				readLiveText()
			} else {
				liveText = WhisperProtocol.applyDiff(old: liveText, chunk: chunk)
			}
		} else if resetInProgress {
            if chunk.isFirstRead() {
                logger.log("Received reset acknowledgement from whisperer")
            } else if chunk.isCompleteLine() {
                logger.debug("Got past line \(self.pastText.pastText.count) in read")
                pastText.addLine(chunk.text)
            } else if chunk.isLastRead() {
                logger.log("Reset completes with \(chunk.text.count) live characters")
                liveText = chunk.text
                resetInProgress = false
            }
		} else {
			logAnomaly("Received unexpected content chunk: \(chunk)", kind: whisperer!.remote.kind)
		}
    }

	private func processControlChunk(remote: Remote, chunk: WhisperProtocol.ProtocolChunk) {
		if chunk.isTranscriptId() {
			transcriptId = chunk.text
			logger.info("Received transcript id \(self.transcriptId, privacy: .public)")
			return
		}
		guard chunk.isPresenceMessage() else {
			logAnomaly("Listener received a non-presence control message: \(chunk)", kind: remote.kind)
			return
		}
		guard let info = WhisperProtocol.ClientInfo.fromString(chunk.text) else {
			logAnomaly("Received a presence message with invalid data: \(chunk)", kind: remote.kind)
			return
		}
		guard !chunk.isRestart() else {
			logger.info("Received restart from \(remote.kind) remote \(remote.id)")
			conversationRestarted = true
			return
		}
		guard conversation.id == info.conversationId else {
			logAnomaly("Ignoring a presence message about the wrong conversation: \(info.conversationId)", kind: remote.kind)
			return
		}
		switch WhisperProtocol.ControlOffset(rawValue: chunk.offset) {
		case .whisperOffer:
			let conversation = profile.forInvite(info: info)
			logger.info("Received offer from \(remote.kind) remote \(remote.id) for conversation \(info.conversationName) from \(info.username)")
			let candidate = candidateFor(remote: remote, info: info, conversation: conversation)
			if candidate.isPending {
				// this is a new invite, so remake the invite list and show it
				refreshStatusText()
			} else {
				// we've already accepted this invite, so try to join
				let conversation = profile.forInvite(info: candidate.info)
				let chunk = WhisperProtocol.ProtocolChunk.listenRequest(conversation)
				transport.sendControl(remote: candidate.remote, chunk: chunk)
			}
		case .listenAuthYes:
			logger.info("Received approval from \(remote.kind) remote \(remote.id) for conversation \(info.conversationName) from \(info.username)")
			let conversation = profile.addForInvite(info: info)
			let candidate = candidateFor(remote: remote, info: info, conversation: conversation)
			if whisperer === candidate {
				logAnomaly("Received second approval for the same conversation", kind: candidate.remote.kind)
				// Whisperer must have restarted, so let them know we're in the conversation
				let chunk = WhisperProtocol.ProtocolChunk.joining(conversation)
				transport.sendControl(remote: candidate.remote, chunk: chunk)
			} else {
				setWhisperer(candidate: candidate, conversation: conversation)
			}
		case .listenAuthNo:
			logger.info("Received refusal from \(remote.kind) remote \(remote.id) for conversation \(info.conversationName) from \(info.username)")
			guard let candidate = candidates[remote.id] else {
				logAnomaly("Ignoring refusal from non-candidate \(remote.id)", kind: remote.kind)
				return
			}
			profile.delete(info.conversationId)
			// drop the remote we heard this from
			if candidate === whisperer {
				logger.warning("Whisperer has deauthorized this listener")
				// make sure we stop listening before we put up the dialog
				stop()
			} else {
				logger.warning("Candidate has refused our listen request")
				dropCandidate(remote)
			}
			connectionErrorSeverity = .endSession
			connectionErrorDescription = "The Whisperer has refused to let you listen"
			connectionError = true
		default:
			logAnomaly("Listener received an unexpected presence message: \(chunk)", kind: remote.kind)
			connectionErrorSeverity = .upgrade
			connectionErrorDescription = "Unexpected presence message"
			connectionError = true
		}
	}

	private func candidateFor(
		remote: Remote,
		info: WhisperProtocol.ClientInfo,
		conversation: ListenConversation
	) -> Candidate {
		conversationName = conversation.name
		if let existing = candidates[remote.id] {
			return existing
		}
		var isPending = !conversation.authorized
		// if my profile is shared, I am always an authorized listener for my own conversations
		if (!UserProfile.shared.userPassword.isEmpty && info.profileId == UserProfile.shared.id) {
			isPending = false
		}
		let candidate = Candidate(remote: remote, info: info, isPending: isPending)
		candidates[candidate.id] = candidate
		return candidate
	}

    private func playSound(_ name: String) {
        var name = name
        var path = Bundle.main.path(forResource: name, ofType: "caf")
        if path == nil {
            // try again with default sound
            name = PreferenceData.alertSound
            path = Bundle.main.path(forResource: name, ofType: "caf")
        }
        guard path != nil else {
            logAnomaly("Couldn't find sound file for '\(name)'")
            return
        }
        guard !isInBackground else {
            notifySound(name)
            return
        }
        let url = URL(filePath: path!)
        soundEffect = try? AVAudioPlayer(contentsOf: url)
        if let player = soundEffect {
            if !player.play() {
				logAnomaly("Couldn't play sound '\(name)'")
            }
        } else {
			logAnomaly("Couldn't create player for sound '\(name)'")
        }
    }
    
	func maybeStartTypingSound() {
		guard PreferenceData.hearTyping && !isInBackground else {
			return
		}
		playTypingSound(PreferenceData.typingSound)
	}

	func maybeEndTypingSound() {
		stopTypingSound()
		guard PreferenceData.hearTyping && !isInBackground else {
			return
		}
		playTypingSound("typewriter-carriage-return")
	}

	func stopTypingSound() {
		if let player = typingPlayer {
			player.stop()
			typingPlayer = nil
		}
	}

	private func playTypingSound(_ name: String) {
		if let path = Bundle.main.path(forResource: name, ofType: "caf") {
			let url = URL(filePath: path)
			typingPlayer = try? AVAudioPlayer(contentsOf: url)
			if let player = typingPlayer {
				player.volume = Float(PreferenceData.typingVolume)
				if !player.play() {
					logAnomaly("Couldn't play \(name) sound")
					typingPlayer = nil
				}
			} else {
				logAnomaly("Can't create player for \(name) sound")
				typingPlayer = nil
			}
		} else {
			logAnomaly("Can't find \(name) sound in main bundle")
			typingPlayer = nil
		}
	}

    private func notifySound(_ name: String) {
        guard notifySoundInBackground else {
            logger.error("Received background request to play sound '\(name, privacy: .public)' but don't have permission.")
            return
        }
        let soundName = UNNotificationSoundName(name + ".caf")
        let sound = UNNotificationSound(named: soundName)
        let content = UNMutableNotificationContent()
        content.title = "Whisper"
        content.body = "The whisperer wants your attention!"
        content.sound = sound
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.25, repeats: false)
        let uuid = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuid, content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in if error != nil { logger.error("Couldn't notify: \(error!, privacy: .public)") } }
    }
    
	private func speak(_ text: String) {
		let onError: (TransportErrorSeverity, String) -> () = { severity, message in
			self.connectionErrorSeverity = severity
			self.connectionErrorDescription = message
			self.connectionError = true
		}
		ElevenLabs.shared.speakText(text: text, errorCallback: onError)
	}

    /// Wait for a while so discovery can find multiple listeners
    private func awaitDiscovery() {
        guard !isInBackground else {
            logAnomaly("Shouldn't happen: Can't start the listener scan in the background")
			return
        }
        logger.log("Start initial wait for whisperers")
        discoveryInProgress = true
        discoveryCountDown = Int(listenerWaitTime + 1)
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(1), repeats: true) { timer in
            guard self.discoveryInProgress && self.discoveryCountDown > 0 else {
                logger.log("End initial wait for whisperers due to timeout")
                timer.invalidate()
                self.discoveryTimer = nil
                self.discoveryCountDown = 0
                self.discoveryInProgress = false
                self.refreshStatusText()
                return
            }
            self.discoveryCountDown -= 1
            self.refreshStatusText()
        }
    }
    
    /// Cancel the wait for discovery
    private func cancelDiscovery() {
        guard let timer = discoveryTimer else {
            return
        }
		logger.log("End initial wait for whisperers explicitly")
        timer.invalidate()
        discoveryTimer = nil
        discoveryInProgress = false
    }
    
	/// subscribe to this candidate
	func setWhisperer(candidate: Candidate, conversation: ListenConversation) {
		guard whisperer == nil else {
			logAnomaly("Ignoring attempt to set whisperer to \(candidate.id) when we already have one (\(self.whisperer!.remote.kind) \(self.whisperer!.id))", kind: candidate.remote.kind)
			return
		}
		logger.info("Selecting \(candidate.remote.kind) whisperer \(candidate.id) for conversation \(conversation.id)")
		whisperer = candidate
		pendingWhisperer = nil
		self.conversation = conversation
		// stop looking for whisperers
		cancelDiscovery()
		refreshStatusText()
		// drop other candidates and invites
		for candidate in Array(candidates.values) {
			if candidate === whisperer {
				continue
			}
			candidates.removeValue(forKey: candidate.id)
			clients.removeValue(forKey: candidate.info.clientId)
			transport.drop(remote: candidate.remote)
		}
		invites.removeAll()
		// tell Whisperer we're subscribing
		let chunk = WhisperProtocol.ProtocolChunk.joining(conversation)
		transport.sendControl(remote: candidate.remote, chunk: chunk)
		transport.subscribe(remote: candidate.remote, conversation: conversation)
		// update the view
		refreshStatusText()
		if isFirstConnect {
			isFirstConnect = false
			pastText.clearLines()
		}
		liveText = ""
		// catch up
		readLiveText()
	}

	private func refreshStatusText() {
		invites = candidates.values.filter{$0.isPending}.sorted()
        if let whisperer = whisperer {
			statusText = "\(conversation.name): Listening to \(whisperer.info.username)"
		} else if let pendingWhisperer = pendingWhisperer {
			statusText = "Waiting for \(pendingWhisperer.info.username) to approve your entry"
		} else {
			let prefix = conversationName.isEmpty ? "" : "\(conversationName): "
			if !invites.isEmpty {
				statusText = "\(prefix)Waiting for you to approve an invite..."
			} else if discoveryInProgress {
				let suffix = discoveryCountDown > 0 ? " \(discoveryCountDown)" : ""
				statusText = "\(prefix)Looking for the Whisperer…\(suffix)"
			} else {
				statusText = "\(prefix)Waiting for the Whisperer…"
			}
		}
		showStatusDetail = !invites.isEmpty
    }

	private func leaveConversation() {
		if let w = whisperer {
			whisperer = nil
			candidates.removeValue(forKey: w.id)
			logger.info("Leaving conversation \(w.info.conversationName) with \(w.info.username)")
			transport.drop(remote: w.remote)
		}
		logger.info("Dropping \(self.candidates.count) remaining candidates")
		for c in Array(candidates.values) {
			transport.drop(remote: c.remote)
		}
		candidates.removeAll()
	}
}
