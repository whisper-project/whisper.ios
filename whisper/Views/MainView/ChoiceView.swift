// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI
import SwiftUIWindowBinder


struct ChoiceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@EnvironmentObject private var sceneDelegate: SceneDelegate

	@AppStorage("whisper_tap_preference") private var whisperTapAction: String?
	@AppStorage("listen_tap_preference") private var listenTapAction: String?
	@AppStorage("main_view_large_sizes_setting") private var useLargeSizes: Bool = false

    @Binding var mode: OperatingMode
	@Binding var conversation: (any Conversation)?
    @Binding var transportStatus: TransportStatus

    @State private var newUsername: String = ""
    @State private var showWhisperButtons = true
    @State private var credentialsMissing = false
    @State private var showWhisperConversations = false
    @State private var showListenConversations = false
	@State private var showFavorites = false
	@State private var showNoConnection = false
	@State private var showSharingSheet = false
    @FocusState private var nameEdit: Bool
	@StateObject private var profile = UserProfile.shared
	@State private var window: Window?

	func nameWidth() -> CGFloat { return useLargeSizes ? 380 : 350 }
	func nameHeight() -> CGFloat { return useLargeSizes ? 145 : 125 }
	func choiceButtonWidth() -> CGFloat {return useLargeSizes ? 170: 140 }
	func choiceButtonHeight() -> CGFloat { return useLargeSizes ? 65 : 45 }

    var body: some View {
		WindowBinder(window: $window) {
			VStack(spacing: 40) {
				nameForm()
				if (showWhisperButtons) {
					if transportStatus != .on {
						transportStatusView()
					}
					HStack(spacing: 30) {
						Button(action: {}) {
							Text("Whisper")
								.foregroundColor(.white)
								.fontWeight(.bold)
								.frame(width: choiceButtonWidth(), height: choiceButtonHeight(), alignment: .center)
						}
						.background(profile.username == "" ? Color.gray : Color.accentColor)
						.cornerRadius(15)
						.disabled(transportStatus == .off)
						.simultaneousGesture(
							LongPressGesture()
								.onEnded { _ in
									showWhisperConversations = true
								}
						)
						.highPriorityGesture(
							TapGesture()
								.onEnded { _ in
									let conversations = profile.whisperProfile.conversations()
									if conversations.count == 1 {
										maybeWhisper(conversations.first)
										return
									}
									switch whisperTapAction {
									case "show":
										showWhisperConversations = true
									case "default":
										maybeWhisper(profile.whisperProfile.fallback)
									case "last":
										if let c = profile.whisperProfile.lastUsed {
											maybeWhisper(c)
										} else {
											showWhisperConversations = true
										}
									default:
										// not set or set to something illegal
										showWhisperConversations = true
									}
								}
						)
						.sheet(isPresented: $showWhisperConversations) {
							WhisperProfileView(maybeWhisper: maybeWhisper)
								.dynamicTypeSize(useLargeSizes ? .accessibility1 : dynamicTypeSize)
						}
						Button(action: {}) {
							Text("Listen")
								.foregroundColor(.white)
								.fontWeight(.bold)
								.frame(width: choiceButtonWidth(), height: choiceButtonHeight(), alignment: .center)
						}
						.background(Color.accentColor)
						.cornerRadius(15)
						.disabled(transportStatus == .off)
						.simultaneousGesture(
							LongPressGesture()
								.onEnded { _ in
									showListenConversations = true
								}
						)
						.highPriorityGesture(
							TapGesture()
								.onEnded { _ in
									let conversations = profile.listenProfile.conversations()
									if conversations.count == 1 {
										maybeListen(conversations.first)
										return
									}
									switch PreferenceData.listenTapAction() {
									case "show":
										showListenConversations = true
									case "last":
										if let c = profile.listenProfile.conversations().first {
											maybeListen(c)
										} else {
											showListenConversations = true
										}
									default:
										// not set or set to something illegal
										showListenConversations = true
									}
								}
						)
						.sheet(isPresented: $showListenConversations) {
							ListenProfileView(maybeListen: maybeListen)
								.dynamicTypeSize(useLargeSizes ? .accessibility1 : dynamicTypeSize)
						}
					}
					.transition(.scale)
				}
				HStack(spacing: 30) {
					Button(action: {
						showFavorites = true
					}) {
						Text("Favorites")
							.foregroundColor(.white)
							.fontWeight(.bold)
							.frame(width: choiceButtonWidth(), height: choiceButtonHeight(), alignment: .center)
					}
					.background(Color.accentColor)
					.cornerRadius(15)
					.sheet(isPresented: $showFavorites) {
						FavoritesProfileView()
							.dynamicTypeSize(useLargeSizes ? .accessibility1 : dynamicTypeSize)
					}
					Button(action: {
						UIApplication.shared.open(settingsUrl)
					}) {
						Text("Settings")
							.foregroundColor(.white)
							.fontWeight(.bold)
							.frame(width: choiceButtonWidth(), height: choiceButtonHeight(), alignment: .center)
					}
					.background(Color.accentColor)
					.cornerRadius(15)
				}
				VStack (spacing: 25) {
					Button(action: {
						UIApplication.shared.open(instructionSite)
					}) {
						Text("How To Use")
							.foregroundColor(.white)
							.fontWeight(.bold)
							.frame(width: choiceButtonWidth() + 50, height: choiceButtonHeight(), alignment: .center)
					}
					.background(Color.accentColor)
					.cornerRadius(15)
					HStack {
						Button("About", action: {
							UIApplication.shared.open(aboutSite)
						})
						.frame(width: choiceButtonWidth(), alignment: .center)
						Spacer()
						Button("Support", action: {
							UIApplication.shared.open(supportSite)
						})
						.frame(width: choiceButtonWidth(), alignment: .center)
					}
					.frame(width: nameWidth())
					Button("Profile Sharing", action: { showSharingSheet = true })
						.disabled(nameEdit)
						.frame(width: choiceButtonWidth() + 50, alignment: .center)
						.sheet(isPresented: $showSharingSheet, content: {
							ShareProfileView()
								.dynamicTypeSize(useLargeSizes ? .accessibility1 : dynamicTypeSize)
						})
				}
			}
			.alert("First Launch", isPresented: $credentialsMissing) {
				Button("OK") { }
			} message: {
				Text("Sorry, but on its first launch after installation the app needs a few minutes to connect to the whisper server. Please try again.")
			}
			.alert("No Connection", isPresented: $showNoConnection) {
				Button("OK") { }
			} message: {
				Text("You must enable a Bluetooth and/or Wireless connection before you can whisper or listen")
			}
			.onChange(of: profile.timestamp, initial: true, updateFromProfile)
			.onChange(of: nameEdit) {
				if nameEdit {
					withAnimation { showWhisperButtons = false }
				} else {
					updateOrRevertProfile()
				}
			}
			.onChange(of: scenePhase) {
				if scenePhase == .active {
					logger.info("ChoiceView has become active")
					profile.update()
				}
			}
			.onAppear(perform: profile.update)
			.onChange(of: window, initial: true) {
				window?.windowScene?.title = nil
			}
		}
    }

	@ViewBuilder func nameForm() -> some View {
		Form {
			Section(header: Text("Your Name")) {
				HStack {
					TextField("Your Name", text: $newUsername, prompt: Text("Fill in to continue…"))
						.submitLabel(.done)
						.focused($nameEdit)
						.textInputAutocapitalization(.never)
						.disableAutocorrection(true)
						.allowsTightening(true)
					Button("Submit", systemImage: "checkmark.square.fill") { nameEdit = false }
						.labelStyle(.iconOnly)
						.disabled(newUsername.isEmpty || newUsername == profile.username)
				}
			}
		}
		.frame(maxWidth: nameWidth(), maxHeight: nameHeight())
	}

	@ViewBuilder func transportStatusView() -> some View {
		switch transportStatus {
		case .off:
			Link("Enable Bluetooth or Wireless to whisper or listen...", destination: settingsUrl)
				.font(FontSizes.fontFor(name: .normal))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		case .localOnly:
			Text("Bluetooth ready, Wireless not available")
				.font(FontSizes.fontFor(name: .normal))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		case .globalOnly:
			Text("Bluetooth not available, Wireless available")
				.font(FontSizes.fontFor(name: .normal))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		case .disabled:
			Link("Bluetooth not enabled, Wireless available", destination: settingsUrl)
				.font(FontSizes.fontFor(name: .normal))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		case .waiting:
			Text("Waiting for Bluetooth, Wireless available")
				.font(FontSizes.fontFor(name: .normal))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		case .on:
			fatalError("Can't happen: transport status is .on")
		}
	}

    func updateFromProfile() {
        newUsername = profile.username
        if profile.username.isEmpty {
			withAnimation {
					showWhisperButtons = false
					nameEdit = true
				}
        }
    }
    
    func updateOrRevertProfile() {
        let proposal = newUsername.trimmingCharacters(in: .whitespaces)
        if proposal.isEmpty {
            updateFromProfile()
        } else {
            newUsername = proposal
            profile.username = proposal
            withAnimation {
                showWhisperButtons = true
            }
        }
    }
    
    func maybeWhisper(_ c: WhisperConversation?) {
        showWhisperConversations = false
		if let c = c {
			if transportStatus == .off {
				showNoConnection = true
			} else {
				conversation = c
				profile.whisperProfile.lastUsed = c
				mode = .whisper
			}
		}
    }
    
    func maybeListen(_ c: ListenConversation?) {
        showListenConversations = false
		if let c = c {
			if transportStatus == .off {
				showNoConnection = true
			} else {
				conversation = c
				mode = .listen
			}
		}
    }
}

#Preview {
    ChoiceView(mode: makeBinding(.ask),
               conversation: makeBinding(nil),
               transportStatus: makeBinding(.on))
}
