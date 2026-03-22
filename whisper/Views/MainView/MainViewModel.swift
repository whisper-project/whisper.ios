// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Combine
import CoreBluetooth

final class MainViewModel: ObservableObject {
    @Published var status: TransportStatus = .on
    
    private var factory = ComboFactory.shared
    private var cancellables: Set<AnyCancellable> = []
    
    init() {
        self.factory.statusSubject
            .sink(receiveValue: setStatus)
            .store(in: &cancellables)
		status = self.factory.statusSubject.value
    }
    
    deinit {
        cancellables.cancel()
    }
    
    private func setStatus(_ new: TransportStatus) {
        status = new
    }
}
