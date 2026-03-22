// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import Combine

final class ComboFactory: TransportFactory {
    typealias Publisher = ComboWhisperTransport
    typealias Subscriber = ComboListenTransport
    
    static let shared = ComboFactory()
    
    var statusSubject: CurrentValueSubject<TransportStatus, Never> = .init(.globalOnly)

    func publisher(_ conversation: WhisperConversation) -> Publisher {
		return Publisher(status: comboStatus, conversation: conversation)
    }
    
    func subscriber(_ conversation: ListenConversation) -> Subscriber {
		return Subscriber(status: comboStatus, conversation: conversation)
    }
    
    //MARK: private types and properties and initialization
	private var comboStatus: TransportStatus = .globalOnly

    private var localFactory = BluetoothFactory.shared
    private var globalFactory = TcpFactory.shared
    
    private var localStatus: TransportStatus
    private var globalStatus: TransportStatus

    private var cancellables: Set<AnyCancellable> = []

    init() {
		localStatus = localFactory.statusSubject.value
		globalStatus = globalFactory.statusSubject.value
		comboStatus = compositeStatus()
        localFactory.statusSubject
            .sink(receiveValue: setLocalStatus)
            .store(in: &cancellables)
        globalFactory.statusSubject
            .sink(receiveValue: setGlobalStatus)
            .store(in: &cancellables)
		statusSubject.send(comboStatus)
    }
    
    deinit {
        cancellables.cancel()
    }

    //MARK: private methods
    func setLocalStatus(_ new: TransportStatus) {
        localStatus = new
		comboStatus = compositeStatus()
        statusSubject.send(comboStatus)
    }
    
    func setGlobalStatus(_ new: TransportStatus) {
        globalStatus = new
		comboStatus = compositeStatus()
        statusSubject.send(comboStatus)
    }
    
    private func compositeStatus() -> TransportStatus {
        switch localStatus {
		case .off:
			return globalStatus == .off ? .off : .globalOnly
		case .waiting:
			return globalStatus == .off ? .off : .globalOnly
        case .disabled:
			return globalStatus == .off ? .off : .globalOnly
        case .on:
			return globalStatus == .off ? .localOnly : .on
		default:
			logAnomaly("Can't happen: localStatus was \(localStatus), assuming .off")
			return globalStatus == .off ? .off : .globalOnly
        }
    }
}
