// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct WhisperStatusTextView: View {
    @Environment(\.colorScheme) private var colorScheme
	@AppStorage("status_buttons_top_preference") private var statusTop: Bool = PreferenceData.statusButtonsTopPreference

    @ObservedObject var model: WhisperViewModel

	private var shareLinkUrl: URL? {
		return URL(string: PreferenceData.publisherUrl(model.conversation))
	}

    private let linkText = UIDevice.current.userInterfaceIdiom == .phone ? "Link" : "Listen Link"
	private let transcriptText = UIDevice.current.userInterfaceIdiom == .phone ? "Transcript" : "Send Transcript"

    var body: some View {
		if statusTop {
			HStack (spacing: 20) {
				statusText
			}
		} else {
			HStack (spacing: 20) {
				if let url = shareLinkUrl {
					ShareLink(linkText, item: url)
						.font(FontSizes.fontFor(name: .xsmall))
				}
				statusText
				if model.transcriptId != nil {
					Button(action: { model.shareTranscript() }, label: {
						Label(transcriptText, systemImage: "eyeglasses")
					})
				}
			}
			.onTapGesture {
				self.model.showStatusDetail.toggle()
			}
		}
    }

	var statusText: some View {
		Text(model.statusText)
			.font(FontSizes.fontFor(name: .xsmall))
			.foregroundColor(colorScheme == .light ? lightLiveTextColor : darkLiveTextColor)
	}
}
