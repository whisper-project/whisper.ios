// Copyright 2025 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.
//
// This source code from Brave-generated AI summary


import SwiftUI
import UIKit

final class OrientationInfo: ObservableObject {
    enum Orientation {
        case portrait, landscape
    }
    
    @Published var orientation: Orientation = .portrait
    
    private var observer: NSObjectProtocol?
    
    init() {
        // Set initial orientation
        self.orientation = UIDevice.current.orientation.isLandscape ? .landscape : .portrait
        
        // Observe changes
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.orientation = UIDevice.current.orientation.isLandscape ? .landscape : .portrait
        }
        
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }
    
    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
