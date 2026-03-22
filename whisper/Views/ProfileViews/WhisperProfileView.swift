// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct WhisperProfileView: View {
	@Environment(\.scenePhase) private var scenePhase
	#if targetEnvironment(macCatalyst)
	@Environment(\.dismiss) private var dismiss
	#endif

	var maybeWhisper: ((WhisperConversation?) -> Void)?

	@State private var path: NavigationPath = .init()
    @State private var rows: [Row] = []
    @State private var defaultConversation: WhisperConversation?
	@StateObject private var profile = UserProfile.shared

    var body: some View {
		NavigationStack(path: $path) {
			List {
				ForEach(rows) { r in
					HStack(spacing: 0) {
						Button(r.id) {
							logger.info("Hit whisper button on \(r.conversation.id) (\(r.id))")
							maybeWhisper?(r.conversation)
						}
							.lineLimit(nil)
							.bold(r.conversation == defaultConversation)
						Spacer(minLength: 20)
						Button("Edit", systemImage: "square.and.pencil") {
							path.append(r.conversation)
						}
							.labelStyle(.iconOnly)
							.font(.title)
					}
					.buttonStyle(.borderless)
				}
				.onDelete { indexSet in
					let conversations = rows.map{r in return r.conversation}
					indexSet.forEach{ profile.whisperProfile.delete(conversations[$0]) }
					updateFromProfile()
				}
			}
			.navigationDestination(for: WhisperConversation.self,
								   destination: { WhisperProfileDetailView(conversation: $0) })
			.navigationTitle("Whisper Conversations")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
#if targetEnvironment(macCatalyst)
				ToolbarItem(placement: .topBarLeading) {
					Button(action: { dismiss() }, label: { Text("Close") } )
				}
#endif
				ToolbarItemGroup(placement: .topBarTrailing) {
					Button(action: addConversation, label: { Image(systemName: "plus") } )
					EditButton()
				}
			}
			.onChange(of: profile.timestamp, initial: true, updateFromProfile)
        }
		.onAppear(perform: profile.update)
		.onDisappear(perform: profile.update)
    }

	private func addConversation() {
		logger.info("Creating new conversation")
		let c = profile.whisperProfile.new()
		updateFromProfile()
		path.append(c)
	}

	private struct Row: Identifiable {
		let id: String
		let conversation: WhisperConversation
	}

    private func updateFromProfile() {
		rows = profile.whisperProfile.conversations().map{ c in return Row(id: c.name, conversation: c) }
		defaultConversation = profile.whisperProfile.fallback
    }
}

#Preview {
    WhisperProfileView()
}
