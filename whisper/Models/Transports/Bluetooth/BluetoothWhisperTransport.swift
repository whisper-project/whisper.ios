// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Combine
import CoreBluetooth

final class BluetoothWhisperTransport: PublishTransport {
    // MARK: Protocol properties and methods
    typealias Remote = Listener
    
    var lostRemoteSubject: PassthroughSubject<Remote, Never> = .init()
    var contentSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()
    var controlSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()

    func start(failureCallback: @escaping TransportErrorCallback) {
        logger.log("Starting Bluetooth whisper transport...")
		running = true
		registerCallbacks()
        startDiscovery()
    }
    
    func stop() {
        logger.log("Stopping Bluetooth whisper transport")
		running = false
        stopDiscovery()
        leaveConversation()
    }

	func canDisconnect() -> Bool {
		return false
	}

	func disconnect() {
		logger.log("Cannot disconnect Bluetooth whisper transport, so stopping instead")
		stop()
	}

    func goToBackground() {
        guard !isInBackground else {
            return
        }
        isInBackground = true
        stopDiscovery()
    }
    
    func goToForeground() {
        guard isInBackground else {
            return
        }
        isInBackground = false
        startDiscovery()
    }
    
	func sendControl(remote: Remote, chunk: WhisperProtocol.ProtocolChunk) {
		guard running else { return }
		logger.info("Sending control packet to \(remote.kind) remote: \(remote.id): \(chunk)")
		logControlChunk(sentOrReceived: "sent", chunk: chunk, kind: .local)
		if var existing = directedControl[remote.central] {
			existing.append(chunk)
		} else {
			directedControl[remote.central] = [chunk]
		}
		updateControl()
	}

    func drop(remote: Remote) {
		guard let existing = remotes[remote.central] else {
			logAnomaly("Ignoring drop request for non-remote: \(remote.id)", kind: .local)
            return
        }
		logger.info("Dropping \(remote.kind) remote \(existing.id)")
		removeRemote(remote)
    }

	func authorize(remote: Remote) {
		guard running else { return }
		guard let existing = remotes[remote.central] else {
			logAnomaly("Ignoring authorization for non-remote: \(remote.id)", kind: .local)
			return
		}
		remote.isAuthorized = true
		// in case they have already connected
		if let index = eavesdroppers.firstIndex(of: existing.central) {
			eavesdroppers.remove(at: index)
			listeners.append(existing.central)
		}
	}

	func deauthorize(remote: Remote) {
		guard running else { return }
		guard let existing = remotes[remote.central] else {
			logAnomaly("Ignoring deauthorization for non-remote: \(remote.id)", kind: .local)
			return
		}
		remote.isAuthorized = false
		// in case they have already connected
		if let index = listeners.firstIndex(of: existing.central) {
			listeners.remove(at: index)
			// they are an eavesdropper until they disconnect or are re-authorized
			eavesdroppers.append(existing.central)
		}
	}

	func sendContent(remote: Remote, chunks: [WhisperProtocol.ProtocolChunk]) {
		guard running else { return }
		if var existing = directedContent[remote.central] {
			existing.append(contentsOf: chunks)
		} else {
			directedContent[remote.central] = chunks
		}
		updateControlAndContent()
	}

    func publish(chunks: [WhisperProtocol.ProtocolChunk]) {
		guard running else { return }
        for chunk in chunks {
            pendingContent.append(chunk)
        }
        updateContent()
    }
    
    // MARK: Peripheral Event Handlers

    private func noticeAd(_ pair: (CBPeripheral, [String: Any])) {
		guard running else { return }
		guard !advertisers.contains(pair.0) else {
			// logger.debug("Ignoring repeat ads from existing advertiser")
			return
		}
		advertisers.append(pair.0)
        if let uuids = pair.1[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            if uuids.contains(BluetoothData.listenServiceUuid) {
                guard let adName = pair.1[CBAdvertisementDataLocalNameKey],
                      let id = adName as? String,
					  id == BluetoothData.deviceId(conversation.id)
                else {
					logAnomaly("Ignoring invalid advertisement from \(pair.0)", kind: .local)
                    return
                }
                logger.debug("Responding to ad from local remote: \(pair.0)")
                startAdvertising()
            }
        }
    }
    
    private func noticeSubscription(_ pair: (CBCentral, CBCharacteristic)) {
		guard running else { return }
		if pair.1.uuid == BluetoothData.controlOutUuid {
			// remote has opened the control channel
			let remote = ensureRemote(pair.0)
			remote.controlSubscribed = true
		} else if pair.1.uuid == BluetoothData.contentOutUuid {
			let remote = ensureRemote(pair.0)
			remote.contentSubscribed = true
			if remote.isAuthorized {
				// add this as an authorized listener
				logger.info("Adding \(remote.kind) content listener: \(remote.id)")
				listeners.append(pair.0)
			} else {
				// this is an eavesdropper
				logAnomaly("Found an eavesdropper: \(pair.0)", kind: .local)
				eavesdroppers.append(pair.0)
			}
		} else {
			logAnomaly("Ignoring subscribe for unexpected characteristic: \(pair.1)", kind: .local)
		}
    }
    
    private func noticeUnsubscription(_ pair: (CBCentral, CBCharacteristic)) {
		if let remote = remotes[pair.0] {
			// unexpected unsubscription, act as if the remote had dropped
			remote.hasDropped = true
			logAnomaly("Unsubscribe by remote \(remote.id) that hasn't dropped", kind: .local)
			removeRemote(remote)
			lostRemoteSubject.send(remote)
		}
		if let removed = removedRemotes[pair.0] {
			// unsubscription from a remote we have removed
			if pair.1.uuid == BluetoothData.contentOutUuid {
				removed.contentSubscribed = false
				if let index = eavesdroppers.firstIndex(of: pair.0) {
					eavesdroppers.remove(at: index)
				}
			} else if pair.1.uuid == BluetoothData.controlOutUuid {
				removed.controlSubscribed = false
			} else {
				logAnomaly("Got unsubscribe for a non-published characteristic: \(pair.1)", kind: .local)
			}
			if !removed.contentSubscribed && !removed.controlSubscribed {
				// the remote has fully disconnected, forget about it
				removedRemotes.removeValue(forKey: pair.0)
			}
		} else {
			logAnomaly("Ignoring unsubscribe from unknown central: \(pair.0)", kind: .local)
        }
		if !running {
			if remotes.isEmpty {
				if removedRemotes.isEmpty {
					logger.info("Shutting down Bluetooth whisper transport after remotes have dropped")
					unregisterCallbacks()
				} else {
					logger.log("Waiting for \(self.removedRemotes.count) dropped remotes to disconnect")
				}
			} else {
				logger.log("Waiting for \(self.remotes.count) listening remotes to disconnect")
			}
		}
    }
    
    private func processReadRequest(_ request: CBATTRequest) {
        logger.log("Received read request \(request)...")
        guard request.offset == 0 else {
            logger.log("Read request has non-zero offset, ignoring it")
            factory.respondToReadRequest(request: request, withCode: .invalidOffset)
            return
        }
        let characteristic = request.characteristic
		logAnomaly("Got a read request for an unexpected characteristic: \(characteristic)", kind: .local)
		factory.respondToReadRequest(request: request, withCode: .attributeNotFound)
    }
    
    private func processWriteRequests(_ requests: [CBATTRequest]) {
        guard let request = requests.first else {
            fatalError("Got an empty write request sequence")
        }
        guard requests.count == 1 else {
            logAnomaly("Got multiple write requests in a batch: \(requests)", kind: .local)
            factory.respondToWriteRequest(request: request, withCode: .requestNotSupported)
            return
        }
		guard request.characteristic.uuid == BluetoothData.controlInUuid else {
            logAnomaly("Got a write request for an unexpected characteristic: \(request)", kind: .local)
            factory.respondToWriteRequest(request: request, withCode: .attributeNotFound)
            return
        }
        guard let value = request.value,
			  let chunk = WhisperProtocol.ProtocolChunk.fromData(value)
        else {
			logAnomaly("Ignoring a malformed write packet: \(request)", kind: .local)
            factory.respondToWriteRequest(request: request, withCode: .unlikelyError)
            return
        }
		logControlChunk(sentOrReceived: "received", chunk: chunk, kind: .local)
		let remote = ensureRemote(request.central)
		if let value = WhisperProtocol.ControlOffset(rawValue: chunk.offset),
		   case .dropping = value {
			logger.info("Received \(value) message from \(remote.kind) remote \(remote.id)")
			remote.hasDropped = true
			removeRemote(remote)
			lostRemoteSubject.send(remote)
			return
		}
		logger.notice("Received control packet from \(remote.kind, privacy: .public) remote \(remote.id, privacy: .public): \(chunk, privacy: .public)")
		controlSubject.send((remote: remote, chunk: chunk))
        factory.respondToWriteRequest(request: request, withCode: .success)
    }
    
    private func updateControlAndContent() {
		if (updateControl()) {
			return
		}
        updateContent()
    }
    
    // MARK: Internal types, properties, and initialization
        
    final class Listener: TransportRemote {
        let id: String
		let kind: TransportKind = .local

        fileprivate var central: CBCentral
		fileprivate var profileId: String?
		fileprivate var contentSubscribed: Bool = false
		fileprivate var controlSubscribed: Bool = false
		fileprivate var isAuthorized: Bool = false
		fileprivate var hasDropped: Bool = false

        fileprivate init(central: CBCentral) {
            self.central = central
			self.id = central.identifier.uuidString
        }
    }

	private var running = false
    private var factory = BluetoothFactory.shared
    private var remotes: [CBCentral: Remote] = [:]
	private var removedRemotes: [CBCentral: Remote] = [:]
    private var liveText: String = ""
    private var pendingContent: [WhisperProtocol.ProtocolChunk] = []
	private var directedContent: [CBCentral: [WhisperProtocol.ProtocolChunk]] = [:]
	private var pendingControl: [WhisperProtocol.ProtocolChunk] = []
	private var directedControl: [CBCentral: [WhisperProtocol.ProtocolChunk]] = [:]
    private var advertisingInProgress = false
    private weak var adTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
	private var listeners: [CBCentral] = []
	private var eavesdroppers: [CBCentral] = []
    private var advertisers: [CBPeripheral] = []
    private var isInBackground = false
    private var conversation: WhisperConversation

    init(_ c: WhisperConversation) {
        logger.log("Initializing Bluetooth whisper transport")
        conversation = c
    }
    
    deinit {
        logger.log("Destroying WhisperView model")
        unregisterCallbacks()
    }

    //MARK: internal methods
    private func startDiscovery() {
		guard running else { return }
        factory.scan(forServices: [BluetoothData.listenServiceUuid], allow_repeats: true)
		advertisers = []
        startAdvertising()
    }
    
    private func stopDiscovery() {
        stopAdvertising()
        factory.stopScan()
    }
    
    /// Send pending content to listeners; returns whether there more to send
    private func updateContent() {
        guard !remotes.isEmpty else {
            // logger.debug("No listeners to update, dumping pending changes")
			directedContent.removeAll()
            pendingContent.removeAll()
            return
        }
        // prioritize individuals over subscribers, because we want to finish
		// updating any specific listeners who are catching up before resuming
		// live updates to everyone
        if !directedContent.isEmpty {
            logger.log("Updating specific listeners...")
            while case ((let listener, var chunks))? = directedContent.first {
                while let chunk = chunks.first {
                    let sendOk = factory.updateValue(value: chunk.toData(),
                                                     characteristic: BluetoothData.contentOutCharacteristic,
                                                     central: listener)
                    if sendOk {
						chunks.removeFirst()
                        if chunks.isEmpty {
                            directedContent.removeValue(forKey: listener)
                        }
                    } else {
                        return
                    }
                }
            }
        }
		if !pendingContent.isEmpty {
            while let chunk = pendingContent.first {
				let sendOk = eavesdroppers.isEmpty ?
							 factory.updateValue(value: chunk.toData(),
												 characteristic: BluetoothData.contentOutCharacteristic) :
							 factory.updateValue(value: chunk.toData(),
												 characteristic: BluetoothData.contentOutCharacteristic,
												 centrals: listeners)
                if sendOk {
                    pendingContent.removeFirst()
                } else {
                    return
                }
            }
        }
		return
    }

    /// Send pending control to listeners, returns whether there is more to send
	@discardableResult private func updateControl() -> Bool {
        if !directedControl.isEmpty {
			while case ((let central, var chunks))? = directedControl.first {
                while let chunk = chunks.first {
                    let sendOk = factory.updateValue(value: chunk.toData(),
                                                     characteristic: BluetoothData.controlOutCharacteristic,
                                                     central: central)
                    if sendOk {
						chunks.removeFirst()
                        if chunks.isEmpty {
                            directedControl.removeValue(forKey: central)
                        }
                    } else {
                        return true
                    }
                }
            }
        }
		if !pendingControl.isEmpty {
			while let chunk = pendingControl.first {
				let sendOk = factory.updateValue(value: chunk.toData(),
												 characteristic: BluetoothData.controlOutCharacteristic)
				if sendOk {
					pendingControl.removeFirst()
				} else {
					return true
				}
			}
		}
		return false
    }

    private func startAdvertising() {
        if advertisingInProgress {
            logger.log("Refresh advertising timer...")
            if let timer = adTimer {
                adTimer = nil
                timer.invalidate()
            }
        } else {
            logger.log("Advertising whisperer...")
        }
		factory.advertise(services: [BluetoothData.whisperServiceUuid], localName: BluetoothData.deviceId(conversation.id))
        advertisingInProgress = true
        let interval = max(listenerAdTime, whispererAdTime)
        adTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            // run loop will invalidate the timer
            self.adTimer = nil
            self.stopAdvertising()
        }
    }
    
    private func stopAdvertising() {
        guard advertisingInProgress else {
            // nothing to do
            return
        }
        logger.log("Stop advertising whisperer")
        factory.stopAdvertising()
        advertisingInProgress = false
        if let timer = adTimer {
            // global cancellation: invalidate the running timer
            adTimer = nil
            timer.invalidate()
        }
		// forget the peripherals which started the advertising,
		// in case they need to rejoin later on.
		advertisers.removeAll()
    }
    
	@discardableResult private func ensureRemote(_ central: CBCentral) -> Remote {
        if let remote = remotes[central] {
            // we've already connected this listener
            return remote
        }
		logger.log("Central \(central) is connecting to the control channel")
		let remote = Remote(central: central)
        remotes[central] = remote
        return remote
    }

	private func removeRemote(_ remote: Remote) {
		remotes.removeValue(forKey: remote.central)
		removedRemotes[remote.central] = remote
		if !remote.hasDropped {
			// tell this remote we're dropping it
			let chunk = WhisperProtocol.ProtocolChunk.dropping()
			sendControl(remote: remote, chunk: chunk)
			if let index = listeners.firstIndex(of: remote.central) {
				listeners.remove(at: index)
				eavesdroppers.append(remote.central)
			}
		}
	}

    private func leaveConversation() {
		guard !remotes.isEmpty else {
			// no listeners, can shut down immediately
			unregisterCallbacks()
			return
		}
		// move all the remotes to removedRemotes
		for remote in Array(remotes.values) {
			removedRemotes[remote.central] = remote
			remotes.removeValue(forKey: remote.central)
		}
		// tell everyone we are leaving the conversation
		logger.info("Dropping all local remotes")
		let chunk = WhisperProtocol.ProtocolChunk.dropping()
		pendingControl.append(chunk)
		updateControl()
		/// once the listeners drop us, we will unregister our callbacks.
		/// but we have a backup in case one of them goes catatonic and doesn't respond
		DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: unregisterCallbacks)
    }

	private func registerCallbacks() {
		logger.info("Registering Bluetooth callbacks")
		factory.advertisementSubject
			.sink { [weak self] in self?.noticeAd($0) }
			.store(in: &cancellables)
		factory.centralSubscribedSubject
			.sink { [weak self] in self?.noticeSubscription($0) }
			.store(in: &cancellables)
		factory.centralUnsubscribedSubject
			.sink { [weak self] in self?.noticeUnsubscription($0) }
			.store(in: &cancellables)
		factory.readRequestSubject
			.sink { [weak self] in self?.processReadRequest($0) }
			.store(in: &cancellables)
		factory.writeRequestSubject
			.sink { [weak self] in self?.processWriteRequests($0) }
			.store(in: &cancellables)
		factory.readyToUpdateSubject
			.sink { [weak self] _ in self?.updateControlAndContent() }
			.store(in: &cancellables)
	}

	private func unregisterCallbacks() {
		logger.info("Unregistering Bluetooth callbacks")
		cancellables.cancel()
		cancellables.removeAll()
	}
}
