// Copyright 2024 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct LinkView: View {
	var conversation: ListenConversation?

	@State private var mode: OperatingMode = .listen
	@State private var restart: Bool = false

    var body: some View {
		if let conversation = conversation, mode == .listen {
			ListenView(mode: $mode, restart: $restart, conversation: conversation)
		} else {
			RootView()
		}
    }
}
