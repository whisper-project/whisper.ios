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
    
    private var localStatus: TransportStatus = .off
    private var globalStatus: TransportStatus = .on

    private var cancellables: Set<AnyCancellable> = []

    init() {
        localFactory.statusSubject
            .sink(receiveValue: setLocalStatus)
            .store(in: &cancellables)
        globalFactory.statusSubject
            .sink(receiveValue: setGlobalStatus)
            .store(in: &cancellables)
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
		guard globalStatus == .off else {
			return .globalOnly
		}
        switch localStatus {
		case .off:
			return .off
		case .waiting:
			return .off
        case .disabled:
			return .off
        case .on:
			return .localOnly
		default:
			logAnomaly("Can't happen: localStatus was \(localStatus), assuming .off")
			return .off
        }
    }
}
