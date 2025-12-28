// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct ListenProfileView: View {
	@Environment(\.scenePhase) private var scenePhase
	#if targetEnvironment(macCatalyst)
	@Environment(\.dismiss) private var dismiss
	#endif

	var maybeListen: ((ListenConversation?) -> Void)?

	@State private var path: NavigationPath = .init()
    @State private var conversations: [ListenConversation] = []
	@State private var myConversations: [WhisperConversation] = []
	@State private var showListenEntry: Bool = false
	@StateObject private var profile = UserProfile.shared

    var body: some View {
		NavigationStack(path: $path) {
			chooseView()
				.navigationDestination(for: String.self, destination: { _ in ListenLinkView(maybeListen: maybeListen) })
				.navigationTitle("Listen Conversations")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
#if targetEnvironment(macCatalyst)
					ToolbarItem(placement: .topBarLeading) {
						Button(action: { dismiss() }, label: { Text("Close") } )
					}
#endif
					ToolbarItem(placement: .topBarTrailing) {
						Button(action: pasteConversation, label: { Image(systemName: "plus") } )
					}
				}
		}
		.onChange(of: profile.timestamp, initial: true, updateFromProfile)
		.onAppear(perform: profile.update)
		.onDisappear(perform: profile.update)
    }

	func pasteConversation() {
		if let url = UIPasteboard.general.url,
		   let conversation = UserProfile.shared.listenProfile.fromLink(url.absoluteString) {
			maybeListen?(conversation)
		} else if let str = UIPasteboard.general.string,
		   let conversation = UserProfile.shared.listenProfile.fromLink(str) {
			maybeListen?(conversation)
		} else {
			path.append("paste")
		}
	}

    func updateFromProfile() {
		conversations = profile.listenProfile.conversations()
		myConversations = profile.userPassword.isEmpty ? [] : profile.whisperProfile.conversations()
    }

	@ViewBuilder func chooseView() -> some View {
		if (myConversations.isEmpty) {
			if (conversations.isEmpty) {
				Form {
					Section("No prior conversations") {
						EmptyView()
					}
				}
			} else {
				listenConversations()
			}
		} else {
			Form {
				Section("Conversations with Others") {
					listenConversations()
				}
				Section("My Conversations") {
					whisperConversations()
				}
			}
		}
	}

	@ViewBuilder func listenConversations() -> some View {
		List(conversations) { c in
			HStack(spacing: 15) {
				Button {
					logger.info("Hit listen button on \(c.id) (\(c.name))")
					maybeListen?(c)
				} label: {
					Text("\(c.name) with \(c.ownerName)")
						.lineLimit(nil)
				}
				Spacer()
				ShareLink("", item: PreferenceData.publisherUrl(c))
				Button("Delete", systemImage: "delete.left") {
					logger.info("Hit delete button on \(c.id) (\(c.name))")
					profile.listenProfile.delete(c.id)
					updateFromProfile()
				}
				.font(.title)
				.labelStyle(.iconOnly)
			}
			.buttonStyle(.borderless)
		}
	}

	@ViewBuilder func whisperConversations() -> some View {
		List(myConversations) { c in
			HStack(spacing: 20) {
				Button("Listen", systemImage: "ear") {
					logger.info("Hit listen button on \(c.id) (\(c.name))")
					maybeListen?(profile.listenProfile.fromMyWhisperConversation(c))
				}
				.font(.title)
				Text("\(c.name)").lineLimit(nil)
				Spacer()
				ShareLink("", item: PreferenceData.publisherUrl(c))
			}
			.labelStyle(.iconOnly)
			.buttonStyle(.borderless)
		}
	}
}

struct ListenLinkView: View {
	var maybeListen: ((ListenConversation?) -> Void)?

	@FocusState private var focus: Bool
	@State private var linkText: String = ""
	@State private var link: String = ""
	@State private var error: Bool = false

	var body: some View {
		Form {
			Section("Enter Listen Link") {
				TextEditor(text: $link)
					.focused($focus)
					.onChange(of: link) { old, new in
						if old.count + 1 == new.count && new.contains("\n") {
							// user typed a newline
							link = old
							DispatchQueue.main.async { maybeJoin() }
						} else if new.contains("\n") {
							// user pasted text with a newline
							error = true
						} else {
							error = false
						}
					}
					.submitLabel(.join)
					.textInputAutocapitalization(.never)
					.disableAutocorrection(true)
					.onSubmit(maybeJoin)
				if error {
					Text("Sorry, that's not a valid listen link")
						.foregroundStyle(.red)
				}
				Button("Join", action: maybeJoin)
					.disabled(error)
			}
		}
		.navigationTitle("New Conversation")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear{ focus = true }
	}

	func maybeJoin() {
		if let conversation = UserProfile.shared.listenProfile.fromLink(link) {
			maybeListen?(conversation)
		} else {
			focus = false
			error = true
		}
	}
}

#Preview {
    ListenProfileView()
}
