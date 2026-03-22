// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import SwiftJWT
import Ably

enum TcpAuthenticatorError: Error {
    case local(String)
    case server(String)
}

final class TcpAuthenticator {
    private var mode: OperatingMode
    private var conversationId: String
	private var conversationName: String
    private var clientId = PreferenceData.clientId
	private var contentId: String
    private var client: ARTRealtime?
    private var failureCallback: TransportErrorCallback
	private var transcriptId: String = "no-transcript"

	init(mode: OperatingMode, conversationId: String, conversationName: String, callback: @escaping TransportErrorCallback) {
        self.mode = mode
        self.conversationId = conversationId
		self.contentId = PreferenceData.getContentId(conversationId)
		self.conversationName = conversationName.isEmpty ? "ListenOffer" : conversationName
        self.failureCallback = callback
    }

	init(conversationId: String) {
		self.mode = .whisper
		self.conversationId = conversationId
		self.contentId = PreferenceData.getContentId(conversationId)
		self.conversationName = ""
		self.failureCallback = {s, m in }
	}

	deinit {
		releaseClient()
	}

    func getClient() -> ARTRealtime {
        if let client = self.client {
            return client
        }
		logger.info("TCP Authenticator: Creating ART Realtime client")
        let options = ARTClientOptions()
		// options.logLevel = .debug
		options.clientId = self.clientId
        options.authCallback = getTokenRequest
        options.autoConnect = true
        options.echoMessages = false
        let client = ARTRealtime(options: options)
        self.client = client
        return client
    }

	func releaseClient() {
		if let client = self.client {
			logger.info("TCP Authenticator: Closing ART Realtime client")
			client.close()
			logger.info("TCP Authenticator: Releasing ART Realtime client")
			self.client = nil
		}
	}

	func getTranscriptId() -> String? {
		if transcriptId != "no-transcript" {
			return transcriptId
		}
		return nil
	}

    private struct ClientClaims: Claims {
        let iss: String
        let exp: Date
    }
    
    private func createJWT() -> String? {
		let secret = PreferenceData.clientSecret()
        guard let secretData = Data(base64Encoded: Data(secret.utf8)) else {
			logAnomaly("Client secret is invalid: \(secret)")
			failureCallback(.reinstall, "Whisper's saved data is missing.")
            return nil
        }
        let claims = ClientClaims(iss: clientId, exp: Date(timeIntervalSinceNow: 300))
        var jwt = JWT(claims: claims)
        let signer = JWTSigner.hs256(key: secretData)
        do {
            return try jwt.sign(using: signer)
        }
        catch let error {
			logAnomaly("Can't create JWT for authentication: \(error)")
			failureCallback(.reinstall, "Whisper is missing a required library.")
            return nil
        }
    }
    
    func getTokenRequest(params: ARTTokenParams, callback: @escaping ARTTokenDetailsCompatibleCallback) {
        if let requestClientId = params.clientId,
           requestClientId != self.clientId
        {
			logAnomaly("Token request client \(requestClientId) doesn't match authenticator client \(clientId)", kind: .global)
        }
        guard let jwt = createJWT() else {
			logAnomaly("Couldn't create JWT to post token request")
            callback(nil, TcpAuthenticatorError.local("Can't create JWT"))
            return
        }
        let activity = mode == .whisper ? "publish" : "subscribe"
		let contentChannelId = mode == .whisper ? contentId : "*"
        var value = [
            "clientId": clientId,
            "activity": mode == .whisper ? "publish" : "subscribe",
            "conversationId": conversationId,
			"conversationName": conversationName,
			"contentId": contentChannelId,
            "profileId": UserProfile.shared.id,
            "username": UserProfile.shared.username,
        ]
		if (mode == .whisper) {
			value["transcribe"] = PreferenceData.doServerSideTranscription() ? "yes" : "no"
		}
        guard let body = try? JSONSerialization.data(withJSONObject: value) else {
            fatalError("Can't encode body for \(activity) token request call")
        }
        guard let url = URL(string: PreferenceData.whisperServer + "/api/v2/pubSubTokenRequest") else {
            fatalError("Can't create URL for \(activity) token request call")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            guard error == nil else {
				logAnomaly("Failed to post \(activity) token request: \(String(describing: error))")
				self.failureCallback(.endSession, "Can't contact the Whisper server.")
                callback(nil, error)
                return
            }
            guard let response = response as? HTTPURLResponse else {
				logAnomaly("Received non-HTTP response on \(activity) token request: \(String(describing: response))")
				self.failureCallback(.endSession, "Having trouble reaching the whisper server.")
                callback(nil, TcpAuthenticatorError.server("Non-HTTP response"))
                return
            }
            if response.statusCode == 403 {
				PreferenceData.resetClientSecret()
				logAnomaly("Received 403 response on \(activity) token request")
				self.failureCallback(.relaunch, "Can't authenticate with the whisper server.")
                callback(nil, TcpAuthenticatorError.server("Authentication failed."))
                return
            }
            if response.statusCode != 200 {
				logAnomaly("Received \(response.statusCode) response on \(activity) token request")
            }
            guard let data = data,
                  let body = try? JSONSerialization.jsonObject(with: data),
                  let obj = body as? [String:String] else {
				logAnomaly("Can't deserialize \(activity) token response body: \(String(decoding: data ?? Data(), as: UTF8.self))")
				self.failureCallback(.endSession, "Having trouble with the whisper server.")
                callback(nil, TcpAuthenticatorError.server("Non-JSON response to token request"))
                return
            }
            guard let tokenRequestString = obj["tokenRequest"] else {
				logAnomaly("Didn't receive a token request value in \(activity) response body: \(obj)")
				self.failureCallback(.endSession, "Having trouble with the whisper server.")
                callback(nil, TcpAuthenticatorError.server("No token request in response"))
                return
            }
            guard let tokenRequest = try? ARTTokenRequest.fromJson(tokenRequestString as ARTJsonCompatible) else {
				logAnomaly("Can't deserialize token request JSON: \(tokenRequestString)")
				self.failureCallback(.endSession, "Having trouble with the whisper server.")
                callback(nil, TcpAuthenticatorError.server("Token request is not expected format"))
                return
            }
			self.transcriptId = obj["transcriptId"] ?? "no-transcript"
			logger.info("Received \(activity, privacy: .public) token from whisper-server, transcript id \(self.transcriptId, privacy: .public)")
            callback(tokenRequest, nil)
        }
        logger.info("Posting \(activity) token request to whisper-server")
        task.resume()
    }

	func getTranscripts(callback: @escaping ([TranscriptData]?) -> Void) {
		guard let jwt = createJWT() else {
			logAnomaly("Couldn't create JWT to post transcript request")
			callback(nil)
			return
		}
		let path = "/api/v2/listTranscripts/\(PreferenceData.clientId)/\(conversationId)"
		guard let url = URL(string: PreferenceData.whisperServer + path) else {
			fatalError("Can't create URL for list transcripts call")
		}
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
		let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
			guard error == nil else {
				logAnomaly("Failed to make list transcripts request: \(String(describing: error))")
				callback(nil)
				return
			}
			guard let response = response as? HTTPURLResponse else {
				logAnomaly("Received non-HTTP response on list transcripts request: \(String(describing: response))")
				callback(nil)
				return
			}
			if response.statusCode == 403 {
				logAnomaly("Received 403 response on list transcripts request")
				callback(nil)
				return
			}
			if response.statusCode != 200 {
				logAnomaly("Received \(response.statusCode) response on list transcripts request")
			}
			guard let data = data,
				  let result = try? JSONDecoder().decode([TranscriptData].self, from: data) else {
				logAnomaly("Can't deserialize list transcripts response body: \(String(decoding: data ?? Data(), as: UTF8.self))")
				callback(nil)
				return
			}
			logger.info("Received \(result.count) transcript descriptors from whisper-server")
			callback(result)
		}
		logger.info("Posting list transcripts request to whisper-server")
		task.resume()
	}
}
