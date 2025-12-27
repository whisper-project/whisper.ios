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
	@EnvironmentObject private var orientationInfo: OrientationInfo

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
	@State private var forceBluetooth: Bool = PreferenceData.forceBluetooth

	func nameWidth() -> CGFloat { return useBigText() ? 380 : 350 }
	func nameHeight() -> CGFloat { return useBigText() ? 145 : 125 }
	func choiceButtonWidth() -> CGFloat {return useBigText() ? 170: 140 }
	func choiceButtonHeight() -> CGFloat { return useBigText() ? 65 : 45 }

    var body: some View {
		WindowBinder(window: $window) {
			VStack(spacing: 0) {
				if platformInfo != "phone" || orientationInfo.orientation != .landscape {
					standardView()
				} else {
					shortWideView()
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
					forceBluetooth = PreferenceData.forceBluetooth
				}
			}
			.onAppear{
				logLifecycle("Choice view appears on scene \(sceneDelegate.id)")
				profile.update()
			}
			.onChange(of: window, initial: true) {
				window?.windowScene?.title = nil
			}
		}
    }

	@ViewBuilder func standardView() -> some View {
		VStack(spacing: 40) {
			nameForm()
			if (showWhisperButtons) {
				transportStatusView(status: transportStatus, internetOk: !forceBluetooth)
				HStack(spacing: 30) {
					whisperButton()
					listenButton()
				}
				.transition(.scale)
			}
			HStack(spacing: 30) {
				favoritesButton()
				settingsButton()
			}
			VStack (spacing: 25) {
				howToUseButton()
				HStack {
					aboutButton()
					Spacer()
					supportButton()
				}
				.frame(width: nameWidth())
				profileSharingButton()
				if platformInfo != "phone" {
					Spacer()
						.frame(height: 25)
					largeSizeToggle()
				}
			}
		}
	}

	@ViewBuilder func shortWideView() -> some View {
		VStack(spacing: 15) {
			nameForm()
			if (showWhisperButtons) {
				transportStatusView(status: transportStatus, internetOk: !forceBluetooth)
				HStack(spacing: 40) {
					whisperButton()
					listenButton()
				}
				.transition(.scale)
			}
			HStack(spacing: 20) {
				favoritesButton()
				settingsButton()
				howToUseButton()
			}
			HStack(spacing: 50) {
				aboutButton()
				supportButton()
				profileSharingButton()
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

	@ViewBuilder func transportStatusView(status: TransportStatus, internetOk: Bool) -> some View {
		switch status {
		case .off:
			Link("Enable Internet or Bluetooth...", destination: settingsUrl)
				.font(FontSizes.fontFor(name: .normal))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		case .localOnly:
			Text("Using Bluetooth (Internet unavailable)")
				.font(FontSizes.fontFor(name: .normal))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		case .globalOnly:
			if internetOk {
				Text("Using Internet (Bluetooth unavailable)")
					.font(FontSizes.fontFor(name: .normal))
					.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
			} else {
				Button("Bluetooth unavailable! (Click for Internet)") {
					PreferenceData.forceBluetooth = false
					forceBluetooth = false
				}
			}
		case .on:
			if internetOk {
				Button("Using Internet (Click for Bluetooth)") {
					PreferenceData.forceBluetooth = true
					forceBluetooth = true
				}
				.font(FontSizes.fontFor(name: .normal))
			} else {
				Button("Using Bluetooth (Click for Internet)") {
					PreferenceData.forceBluetooth = false
					forceBluetooth = false
				}
				.font(FontSizes.fontFor(name: .normal))
			}
		default:
			Text("Error obtaining network status. Please restart the app.")
				.font(FontSizes.fontFor(name: .large))
				.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
		}
	}

	@ViewBuilder func whisperButton() -> some View {
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
				.dynamicTypeSize(useBigText() ? .accessibility1 : dynamicTypeSize)
		}
	}

	@ViewBuilder func listenButton() -> some View {
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
				.dynamicTypeSize(useBigText() ? .accessibility1 : dynamicTypeSize)
		}
	}

	@ViewBuilder func favoritesButton() -> some View {
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
				.dynamicTypeSize(useBigText() ? .accessibility1 : dynamicTypeSize)
		}
	}

	func settingsButton() -> some View {
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

	@ViewBuilder func howToUseButton() -> some View {
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
	}

	@ViewBuilder func aboutButton() -> some View {
		Button("About v\(versionString)", action: {
			UIApplication.shared.open(aboutSite)
		})
	}

	@ViewBuilder func supportButton() -> some View {
		Button("Support", action: {
			UIApplication.shared.open(supportSite)
		})
	}

	@ViewBuilder func profileSharingButton() -> some View {
		Button("Profile Sharing", action: { showSharingSheet = true })
			.disabled(nameEdit)
			.sheet(isPresented: $showSharingSheet, content: {
				ShareProfileView()
					.dynamicTypeSize(useBigText() ? .accessibility1 : dynamicTypeSize)
			})
	}

	@ViewBuilder func largeSizeToggle() -> some View {
		Toggle("Larger Type", isOn: $useLargeSizes)
			.frame(maxWidth: useLargeSizes ? 260 : 205)
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

	func useBigText() -> Bool {
		useLargeSizes && platformInfo != "phone"
	}
}

#Preview {
    ChoiceView(mode: makeBinding(.ask),
               conversation: makeBinding(nil),
               transportStatus: makeBinding(.on))
}
