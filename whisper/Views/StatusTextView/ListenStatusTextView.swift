// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct ListenStatusTextView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: ListenViewModel

	private var shareLinkUrl: URL? {
		return URL(string: PreferenceData.publisherUrl(model.conversation))
	}

    private let linkText = UIDevice.current.userInterfaceIdiom == .phone ? "Link" : "Listen Link"
	private let transcriptText = UIDevice.current.userInterfaceIdiom == .phone ? "Transcript" : "View Transcript"

    var body: some View {
		HStack (spacing: 20) {
			if let url = shareLinkUrl {
				ShareLink(linkText, item: url)
					.font(FontSizes.fontFor(name: .xsmall))
			}
			statusText
			if let transcriptId = model.transcriptId {
				Link(destination: transcriptLink(id: transcriptId), label: {
					Label(transcriptText, systemImage: "eyeglasses")
				})
			}
		}
    }

	var statusText: some View {
		Text(model.statusText)
			.font(FontSizes.fontFor(name: .xsmall))
			.foregroundColor(colorScheme == .light ? lightLiveTextColor : darkLiveTextColor)
	}

	private func transcriptLink(id: String) -> URL {
		return URL(string: "\(PreferenceData.whisperServer)/transcript/\(model.conversation.id)/\(id)")!
	}
}
