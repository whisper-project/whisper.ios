// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import Combine

enum TransportStatus: String {
    case off = "off"
	case localOnly = "localOnly"
	case globalOnly = "globalOnly"
    case disabled = "disabled"
    case waiting = "waiting"
    case on = "on"
}

enum TransportErrorSeverity {
	case temporary
	case settings
	case report
	case upgrade
	case endSession
	case relaunch
	case reinstall
}

typealias TransportSuccessCallback = ((TransportErrorSeverity, String)?) -> Void
typealias TransportErrorCallback = (TransportErrorSeverity, String) -> Void

enum TransportKind: CustomStringConvertible {
	case local
	case global

	var description: String {
		switch self {
		case .local:
			return "local"
		case .global:
			return "global"
		}
	}
}

protocol TransportFactory {
    associatedtype Publisher: PublishTransport
    associatedtype Subscriber: SubscribeTransport
    
    static var shared: Self { get }
    
    var statusSubject: CurrentValueSubject<TransportStatus, Never> { get }
    
    func publisher(_ conversation: WhisperConversation) -> Publisher
    func subscriber(_ conversation: ListenConversation) -> Subscriber
}

protocol TransportRemote: Identifiable {
	var id: String { get }
	var kind: TransportKind { get }
}

protocol Transport {
    associatedtype Remote: TransportRemote

    var controlSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> { get }
	var lostRemoteSubject: PassthroughSubject<Remote, Never> { get }

    func start(failureCallback: @escaping TransportErrorCallback)
    func stop()

    func goToBackground()
    func goToForeground()
    
    func sendControl(remote: Remote, chunk: WhisperProtocol.ProtocolChunk)

    func drop(remote: Remote)
}

protocol PublishTransport: Transport {
	init(_ conversation: WhisperConversation)

	func canDisconnect() -> Bool
	func disconnect()

	func authorize(remote: Remote)
	func deauthorize(remote: Remote)

    func sendContent(remote: Remote, chunks: [WhisperProtocol.ProtocolChunk])
    func publish(chunks: [WhisperProtocol.ProtocolChunk])
}

protocol SubscribeTransport: Transport {
	init(_ conversation: ListenConversation)

	var contentSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> { get }

	func subscribe(remote: Remote, conversation: ListenConversation)
}
