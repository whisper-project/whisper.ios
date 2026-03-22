// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation

final class PastTextModel: ObservableObject {
    @Published var pastText: String = ""
	@Published var rawPastText: String = ""
    @Published private(set) var addLinesAtTop = false
    
    init(mode: OperatingMode, initialText: String = "") {
        if mode == .listen && !PreferenceData.listenerMatchesWhisperer() {
            addLinesAtTop = true
        }
		rawPastText = initialText
        pastText = addLinks(initialText)
    }
    
    func addLine(_ line: String) {
		addLineInternal(line)
    }

	private func addLineInternal(_ line: String) {
		let linked = addLinks(line)
		if pastText.isEmpty {
			rawPastText = line
			pastText = linked
		} else if addLinesAtTop {
			rawPastText = line + "\n" + pastText
			pastText = linked + "\n" + pastText
		} else {
			rawPastText += "\n" + line
			pastText += "\n" + linked
		}
	}

    func clearLines() {
		rawPastText = ""
        pastText = ""
    }
    
	func getLines() -> (raw: [String], linked: [String]) {
		if pastText.isEmpty {
			return (raw: [], linked: [])
		}
		var rawLines = rawPastText.split(separator: "\n", omittingEmptySubsequences: false)
        var lines = pastText.split(separator: "\n", omittingEmptySubsequences: false)
        if addLinesAtTop {
			rawLines.reverse()
            lines.reverse()
        }
		return (raw: rawLines.map{ String($0) }, linked: lines.map{ String($0) })
    }

	func getText() -> String {
		rawPastText
	}

	func setFromText(_ text: String) {
		clearLines()
		addText(text)
	}

    func addText(_ text: String) {
		if text.isEmpty {
			return
		}
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            addLineInternal(String(line))
        }
    }
    
	func addLinks(_ text: String) -> String {
		if text.isEmpty {
			return text
		}
		guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
			logAnomaly("Couldn't create NSDataDetector for link checking in past text")
			return text
		}
		var text = text
		let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
		for match in matches.reversed() {
			guard let range = Range(match.range, in: text) else {
				continue
			}
			let content = String(text[range])
			let prefix = (content.prefixMatch(of: /[a-zA-Z]+:\/\//) != nil) ? "" : "https://"
			if let url = URL(string: prefix + content) {
				let host = url.host() ?? content
				text.replaceSubrange(range, with: "[\(host)](\(url.absoluteString))")
			}
		}
		return text
	}
}
