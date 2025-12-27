// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct MainView: View {
    @Environment(\.colorScheme) private var colorScheme
	@Environment(\.openWindow) private var openWindow
	@Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var mode: OperatingMode
    @Binding var conversation: (any Conversation)?

	@State var restart: Bool = false
    @StateObject private var model: MainViewModel = .init()
            
    var body: some View {
        switch mode {
        case .ask:
			ChoiceView(mode: $mode, conversation: $conversation, transportStatus: $model.status)
			.alert("Conversation Paused", isPresented: $restart) {
				Button("OK") { mode = .listen }
				Button("Cancel") {}
			} message: {
				Text("The Whisperer has paused the conversation. Click OK to reconnect, Cancel to stop listening.")
			}
        case .listen:
			ListenView(mode: $mode, restart: $restart, conversation: conversation as! ListenConversation)
        case .whisper:
			WhisperView(mode: $mode, conversation: conversation as! WhisperConversation)
        }
    }
}
