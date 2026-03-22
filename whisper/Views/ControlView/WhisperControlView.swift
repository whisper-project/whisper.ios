// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct WhisperControlView: View {
	@Environment(\.colorScheme) private var colorScheme
	@AppStorage("typing_volume_setting") private var typingVolume: Double = PreferenceData.typingVolume
	@AppStorage("status_buttons_top_preference") private var statusTop: Bool = PreferenceData.statusButtonsTopPreference

	@Binding var size: FontSizes.FontSize
	@Binding var status: Bool
	@Binding var magnify: Bool
	@Binding var interjecting: Bool
	@Binding var showFavorites: Bool
	@Binding var group: FavoritesGroup
	var maybeStop: () -> Void
	var playSound: () -> Void
	var repeatSpeech: (String?) -> Void
	var editFavorites: () -> Void
	var clearTyping: () -> Void

	@State private var alertSound = PreferenceData.alertSound
	@State private var typing = PreferenceData.hearTyping
	@State private var typingSound = PreferenceData.typingSound
	@State private var speaking: Bool = false
	@State private var allGroups: [FavoritesGroup] = []
	@StateObject private var fp = UserProfile.shared.favoritesProfile

	var body: some View {
		HStack(alignment: .center) {
			if statusTop {
				statusButton()
			}
			alarmButton()
			typingButton()
			speechButton()
			clearButton()
			repeatButton()
			interjectingButton()
			favoritesButton()
			maybeFontSizeButtons()
			maybeFontSizeToggle()
			stopButton()
		}
		.dynamicTypeSize(.large)
		.font(FontSizes.fontFor(FontSizes.minTextSize))
		.onChange(of: fp.timestamp, initial: true, updateFromProfile)
	}

	private func updateFromProfile() {
		speaking = PreferenceData.speakWhenWhispering
		allGroups = fp.allGroups()
	}

	@ViewBuilder private func statusButton() -> some View {
		Button {
			status.toggle()
		} label: {
			buttonImage(systemName: "person.crop.circle.badge.questionmark.fill", pad: 5)
		}
		Spacer()
	}

	@ViewBuilder private func alarmButton() -> some View {
		Menu {
			ForEach(PreferenceData.alertSoundChoices) { choice in
				Button {
					alertSound = choice.id
					PreferenceData.alertSound = choice.id
				} label: {
					Label(choice.name, image: choice.id + "-icon")
				}
			}
		} label: {
			buttonImage(name: alertSound + "-icon", pad: 5)
		} primaryAction: {
			playSound()
		}
		Spacer()
	}

	@ViewBuilder private func speechButton() -> some View {
		Button {
			speaking.toggle()
			PreferenceData.speakWhenWhispering = speaking
		} label: {
			buttonImage(name: speaking ? "voice-over-on" : "voice-over-off", pad: 5)
		}
		Spacer()
	}

	@ViewBuilder private func clearButton() -> some View {
		Button {
			clearTyping()
		} label: {
			buttonImage(systemName: "eraser", pad: 5)
		}
		Spacer()
	}

	@ViewBuilder private func typingButton() -> some View {
		Menu {
			Button {
				typingVolume = 1
				PreferenceData.typingVolume = 1
			} label: {
				if typingVolume == 1 {
					Label("Loud Typing", systemImage: "checkmark.square")
				} else {
					Label("Loud Typing", systemImage: "speaker.wave.3")
				}
			}
			Button {
				typingVolume = 0.5
				PreferenceData.typingVolume = 0.5
			} label: {
				if typingVolume == 0.5 {
					Label("Medium Typing", systemImage: "checkmark.square")
				} else {
					Label("Medium Typing", systemImage: "speaker.wave.2")
				}
			}
			Button {
				typingVolume = 0.25
				PreferenceData.typingVolume = 0.25
			} label: {
				if typingVolume == 0.25 {
					Label("Quiet Typing", systemImage: "checkmark.square")
				} else {
					Label("Quiet Typing", systemImage: "speaker.wave.1")
				}
			}
			ForEach(PreferenceData.typingSoundChoices, id: \.0) { tuple in
				Button {
					PreferenceData.typingSound = tuple.2
					typingSound = tuple.2
				} label: {
					if typingSound == tuple.2 {
						Label(tuple.1, systemImage: "checkmark.square")
					} else {
						Label(tuple.1, systemImage: "square")
					}
				}
			}
		} label: {
			buttonImage(name: typing ? "typing-bubble" : "typing-no-bubble", pad: 5)
		} primaryAction: {
			typing.toggle()
			PreferenceData.hearTyping = typing
		}
		Spacer()
	}

	@ViewBuilder private func repeatButton() -> some View {
		Button {
			repeatSpeech(nil)
		} label: {
			buttonImage(name: "repeat-speech", pad: 5)
		}
		Spacer()
	}

	@ViewBuilder private func interjectingButton() -> some View {
		Button {
			interjecting.toggle()
		} label: {
			buttonImage(name: interjecting ? "interjecting" : "not-interjecting", pad: 5)
		}
		Spacer()
	}

	@ViewBuilder private func favoritesButton() -> some View {
		Menu {
			Button("All", action: { toggleShowFavorites(fp.allGroup) })
			ForEach(allGroups) { group in
				Button(action: { toggleShowFavorites(group) }, label: { Text(group.name) })
			}
			Button("Edit Favorites", action: { editFavorites() })
		} label: {
			buttonImage(systemName: showFavorites ? "star.fill" : "star", pad: 5)
		} primaryAction: {
			toggleShowFavorites()
		}
		Spacer()
	}

	@ViewBuilder private func maybeFontSizeButtons() -> some View {
		if isOnPhone() {
			EmptyView()
		} else {
			Button {
				self.size = FontSizes.nextTextSmaller(self.size)
				PreferenceData.sizeWhenWhispering = self.size
			} label: {
				buttonImage(name: "font-down-button", pad: 0)
			}
			.disabled(size == FontSizes.minTextSize)
			Button {
				self.size = FontSizes.nextTextLarger(self.size)
				PreferenceData.sizeWhenWhispering = self.size
			} label: {
				buttonImage(name: "font-up-button", pad: 0)
			}
			.disabled(size == FontSizes.maxTextSize)
			Spacer()
		}
	}

	@ViewBuilder private func maybeFontSizeToggle() -> some View {
		if isOnPhone() {
			EmptyView()
		} else {
			Toggle(isOn: $magnify) {
				Text("Large Sizes")
					.lineLimit(2)
			}
			.onChange(of: magnify) {
				PreferenceData.magnifyWhenWhispering = magnify
			}
			.frame(minWidth: 125, maxWidth: 170)
			Spacer()
		}
	}

	private func toggleShowFavorites(_ group: FavoritesGroup? = nil) {
		if let group = group {
			self.group = group
			PreferenceData.currentFavoritesGroup = group
			if !showFavorites {
				showFavorites = true
				PreferenceData.showFavorites = true
			}
		} else {
			showFavorites.toggle()
			PreferenceData.showFavorites = showFavorites
		}
	}

	@ViewBuilder private func stopButton() -> some View {
		Spacer()
		Button {
			maybeStop()
		} label: {
			buttonImage(systemName: "exclamationmark.octagon.fill", pad: 5)
				.foregroundStyle(.red)
		}
	}

	private func buttonImage(name: String, pad: CGFloat) -> some View {
		Image(name)
			.renderingMode(.template)
			.resizable()
			.padding(pad)
			.frame(width: buttonSize(), height: buttonSize())
			.border(colorScheme == .light ? .black : .white, width: 1)
	}

	private func buttonImage(systemName: String, pad: CGFloat) -> some View {
		Image(systemName: systemName)
			.renderingMode(.template)
			.resizable()
			.padding(pad)
			.frame(width: buttonSize(), height: buttonSize())
			.border(colorScheme == .light ? .black : .white, width: 1)
	}

	private func isOnPhone() -> Bool {
		return UIDevice.current.userInterfaceIdiom == .phone
	}

	private func buttonSize() -> CGFloat {
		if isOnPhone() {
			if UIScreen.main.bounds.width < 390 {
				35
			} else {
				40
			}
		} else {
			50
		}
	}
}
