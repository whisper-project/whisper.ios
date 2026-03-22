// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

// this code adapted from https://stackoverflow.com/a/73594756/558006

import Foundation
import Network
import Combine

final class TcpMonitor {
    var statusSubject: CurrentValueSubject<TransportStatus, Never> = .init(.on)

    private var monitor: NWPathMonitor
    
    init() {
        monitor = NWPathMonitor()
        
        monitor.pathUpdateHandler = { [weak self] path in
            switch path.status {
            case .satisfied:
                self?.statusSubject.send(.on)
            case .unsatisfied, .requiresConnection:
                self?.statusSubject.send(.off)
            @unknown default:
                self?.statusSubject.send(.on)
            }
        }
        
        monitor.start(queue: DispatchQueue.main)
    }
}
