// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import Combine

final class ComboWhisperTransport: PublishTransport {
    // MARK: protocol properties and methods
    typealias Remote = Wrapper
    
    var lostRemoteSubject: PassthroughSubject<Remote, Never> = .init()
	var controlSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()
	var contentSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()

    func start(failureCallback: @escaping TransportErrorCallback) {
        logger.log("Starting combo whisper transport")
        self.failureCallback = failureCallback
        initializeTransports()
        staggerStart()
    }
    
    func stop() {
        logger.log("Stopping combo whisper transport")
		staggerStop(.local)
		staggerStop(.global)
    }

	func canDisconnect() -> Bool {
		let localCan = localTransport == nil || localTransport!.canDisconnect()
		let globalCan = globalTransport == nil || globalTransport!.canDisconnect()
		return localCan && globalCan
	}

	func disconnect() {
		logger.log("Disconnecting combo whisper transport")
		staggerDisconnect(.local)
		staggerDisconnect(.global)
	}

    func goToBackground() {
        localTransport?.goToBackground()
        globalTransport?.goToBackground()
    }
    
    func goToForeground() {
        localTransport?.goToForeground()
        globalTransport?.goToForeground()
    }
    
    func sendContent(remote: Remote, chunks: [WhisperProtocol.ProtocolChunk]) {
        guard let remote = remotes[remote.id] else {
			logAnomaly("Sending content to an unknown remote: \(remote.id)", kind: remote.kind)
			return
        }
        switch remote.kind {
        case .local:
            localTransport?.sendContent(remote: remote.inner as! LocalRemote, chunks: chunks)
        case .global:
            globalTransport?.sendContent(remote: remote.inner as! GlobalRemote, chunks: chunks)
        }
    }

    func sendControl(remote: Remote, chunk: WhisperProtocol.ProtocolChunk) {
        guard let remote = remotes[remote.id] else {
			logAnomaly("Sending control to an unknown remote: \(remote.id)", kind: remote.kind)
			return
        }
        switch remote.kind {
        case .local:
            localTransport?.sendControl(remote: remote.inner as! LocalRemote, chunk: chunk)
        case .global:
            globalTransport?.sendControl(remote: remote.inner as! GlobalRemote, chunk: chunk)
        }
    }

    func drop(remote: Remote) {
		guard let remote = remotes.removeValue(forKey: remote.id) else {
			logAnomaly("Dropping an unknown remote: \(remote.id)", kind: remote.kind)
			return
        }
		clients.removeValue(forKey: remote.clientId)
        switch remote.kind {
        case .local:
            localTransport?.drop(remote: remote.inner as! LocalRemote)
        case .global:
            globalTransport?.drop(remote: remote.inner as! GlobalRemote)
        }
    }
    
	func authorize(remote: Remote) {
		guard let remote = remotes[remote.id] else {
			logAnomaly("Authorizing an unknown remote: \(remote.id)", kind: remote.kind)
			return
		}
		switch remote.kind {
		case .local:
			localTransport?.authorize(remote: remote.inner as! LocalRemote)
		case .global:
			globalTransport?.authorize(remote: remote.inner as! GlobalRemote)
		}
	}

	func deauthorize(remote: Remote) {
		guard let remote = remotes[remote.id] else {
			logAnomaly("Deauthorizing an unknown remote: \(remote.id)", kind: remote.kind)
			return
		}
		switch remote.kind {
		case .local:
			localTransport?.deauthorize(remote: remote.inner as! LocalRemote)
		case .global:
			globalTransport?.deauthorize(remote: remote.inner as! GlobalRemote)
		}
	}

    func publish(chunks: [WhisperProtocol.ProtocolChunk]) {
        localTransport?.publish(chunks: chunks)
        globalTransport?.publish(chunks: chunks)
    }

	// pass through of global-only method
	func getTranscriptId() -> String? {
		return globalTransport?.getTranscriptId()
	}

    // MARK: internal types, properties, and initialization
    typealias LocalTransport = BluetoothWhisperTransport
    typealias LocalRemote = BluetoothWhisperTransport.Remote
    typealias GlobalTransport = TcpWhisperTransport
    typealias GlobalRemote = TcpWhisperTransport.Remote

    final class Wrapper: TransportRemote {
		let id: String
		let kind: TransportKind

		fileprivate var inner: (any TransportRemote)
		fileprivate var clientId: String

		init(inner: any TransportRemote, clientId: String) {
			self.inner = inner
			self.id = inner.id
			self.kind = inner.kind
			self.clientId = clientId
		}
    }
    
    private var localFactory = BluetoothFactory.shared
    private var localStatus: TransportStatus = .off
    private var localTransport: LocalTransport?
    private var globalFactory = TcpFactory.shared
    private var globalStatus: TransportStatus = .off
    private var globalTransport: TcpWhisperTransport?
    private var remotes: [String: Remote] = [:]	// maps from remote id to remote
	private var clients: [String: Remote] = [:]	// maps from client id to remote
    private var cancellables: Set<AnyCancellable> = []
	private var transportStatus: TransportStatus
    private var conversation: WhisperConversation
    private var failureCallback: TransportErrorCallback?
	private var staggerTimer: Timer?

	init(_ conversation: WhisperConversation) {
		logger.log("Initializing combo whisper transport with status .on")
		self.transportStatus = .on
		self.conversation = conversation
		self.localFactory.statusSubject
			.sink(receiveValue: setLocalStatus)
			.store(in: &cancellables)
		self.globalFactory.statusSubject
			.sink(receiveValue: setGlobalStatus)
			.store(in: &cancellables)
	}

	init(status: TransportStatus, conversation: WhisperConversation) {
		logger.log("Initializing combo whisper transport with status .\(status.rawValue, privacy: .public)")
		self.transportStatus = status
		self.conversation = conversation
		self.localFactory.statusSubject
			.sink(receiveValue: setLocalStatus)
			.store(in: &cancellables)
		self.globalFactory.statusSubject
			.sink(receiveValue: setGlobalStatus)
			.store(in: &cancellables)
	}

    deinit {
        logger.log("Destroying combo whisper transport")
        cancellables.cancel()
    }
    
    //MARK: internal methods
    private func setLocalStatus(_ status: TransportStatus) {
        guard localStatus != status else {
            return
        }
		logger.debug("The Bluetooth status has transitioned to \(status.rawValue, privacy: .public)")
        localStatus = status
    }
    
    private func setGlobalStatus(_ status: TransportStatus) {
        guard globalStatus != status else {
            return
        }
		logger.debug("The TCP status has transitioned to \(status.rawValue, privacy: .public)")
        globalStatus = status
    }
    
    private func initializeTransports() {
		if (transportStatus == .localOnly || transportStatus == .on) && localStatus == .on {
            let localTransport = LocalTransport(conversation)
            self.localTransport = localTransport
            localTransport.lostRemoteSubject
                .sink { [weak self] in self?.removeRemote(remote: $0) }
                .store(in: &cancellables)
			localTransport.controlSubject
				.sink { [weak self] in self?.receiveControlChunk(remote: $0.remote, chunk: $0.chunk) }
				.store(in: &cancellables)
        }
		if (transportStatus == .globalOnly || transportStatus == .on) && globalStatus == .on {
			let globalTransport = GlobalTransport(conversation)
			self.globalTransport = globalTransport
			globalTransport.lostRemoteSubject
				.sink { [weak self] in self?.removeRemote(remote: $0) }
				.store(in: &cancellables)
			globalTransport.controlSubject
				.sink { [weak self] in self?.receiveControlChunk(remote: $0.remote, chunk: $0.chunk) }
				.store(in: &cancellables)
        }
        if localTransport == nil && globalTransport == nil {
            logger.error("No transports available for whispering")
			failureCallback?(.endSession, "Cannot whisper unless one of Bluetooth or wireless data is available")
        }
    }
    
	private func staggerStart() {
		if let global = globalTransport {
			logger.info("Starting Global whispering in advance of Local")
			global.start(failureCallback: self.failureCallback!)
			staggerTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(listenerWaitTime), repeats: false) { _ in
				// run loop will invalidate the timer
				self.staggerTimer = nil
				if let local = self.localTransport {
					logger.info("Starting Local whispering after Global")
					local.start(failureCallback: self.failureCallback!)
				}
			}
		} else if let local = localTransport {
			logger.info("Starting only Local whispering")
			local.start(failureCallback: failureCallback!)
		} else {
			logAnomaly("Cannot whisper because neither Global nor Local is available")
			self.failureCallback?(.endSession, "Cannot whisper because all forms of networking are unavailable")
		}
	}

	private func staggerDisconnect(_ kind: TransportKind) {
		if let timer = staggerTimer {
			staggerTimer = nil
			timer.invalidate()
		}
		switch kind {
		case .local:
			localTransport?.disconnect()
		case .global:
			globalTransport?.disconnect()
		}
	}

	private func staggerStop(_ kind: TransportKind) {
		if let timer = staggerTimer {
			staggerTimer = nil
			timer.invalidate()
		}
		switch kind {
		case .local:
			localTransport?.stop()
		case .global:
			globalTransport?.stop()
		}
	}

	private func removeRemote(remote: any TransportRemote) {
        guard let removed = remotes.removeValue(forKey: remote.id) else {
			logAnomaly("Ignoring drop of unknown remote \(remote.id)", kind: remote.kind)
            return
        }
		clients.removeValue(forKey: removed.clientId)
        lostRemoteSubject.send(removed)
    }
    
	private func receiveControlChunk(remote: any TransportRemote, chunk: WhisperProtocol.ProtocolChunk) {
		if let remote = remoteFor(remote: remote, chunk: chunk) {
			controlSubject.send((remote: remote, chunk: chunk))
		}
	}

	private func remoteFor(remote: any TransportRemote, chunk: WhisperProtocol.ProtocolChunk) -> Remote? {
		if let remote = remotes[remote.id] {
			return remote
		}
		guard chunk.isPresenceMessage(), let info = WhisperProtocol.ClientInfo.fromString(chunk.text) else {
			logAnomaly("Non-presence initial control packet received from remote: \(remote.id)", kind: remote.kind)
			return nil
		}
		guard clients[info.clientId] == nil else {
			logger.info("Refusing second appearance of client via different network: \(remote.kind)")
			switch remote.kind {
			case .local:
				localTransport?.drop(remote: remote as! LocalRemote)
			case .global:
				globalTransport?.drop(remote: remote as! GlobalRemote)
			}
			return nil
		}
		let remote = Wrapper(inner: remote, clientId: info.clientId)
		remotes[remote.id] = remote
		clients[info.clientId] = remote
		return remote
	}
}
