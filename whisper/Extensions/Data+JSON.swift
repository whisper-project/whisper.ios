// Copyright 2024 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation

extension Data {
	@discardableResult func saveJsonToDocumentsDirectory(_ filename: String) -> Bool {
		do {
			let folderURL = try FileManager.default.url(
				for: .documentDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: false
			)
			let fileUrl = folderURL.appendingPathComponent("\(filename).json")
			try self.write(to: fileUrl)
			return true
		}
		catch (let err) {
			logAnomaly("Failed to write \(filename).json: \(err)")
			return false
		}
	}

	static func loadJsonFromDocumentsDirectory(_ filename: String) -> Data? {
		do {
			let folderURL = try FileManager.default.url(
				for: .documentDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: false
			)
			let fileUrl = folderURL.appendingPathComponent("\(filename).json")
			let data = try Data(contentsOf: fileUrl)
			return data
		}
		catch (let err) {
			logAnomaly("Failure reading \(filename).json: \(err)")
			return nil
		}
	}

	@discardableResult static func removeJsonFromDocumentsDirectory(_ filename: String) -> Bool {
		do {
			let folderURL = try FileManager.default.url(
				for: .documentDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: false
			)
			let fileUrl = folderURL.appendingPathComponent("\(filename).json")
			try FileManager.default.removeItem(at: fileUrl)
			return true
		}
		catch (let err) {
			logAnomaly("Failure deleting \(filename).json: \(err)")
			return false
		}
	}

	@discardableResult static func executeJSONRequest(_ request: URLRequest, handler: ((Int, Data) -> Void)? = nil) -> URLSessionDataTask {
		let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
			guard error == nil else {
				logger.error("Failed to execute \(request, privacy: .public): \(String(describing: error), privacy: .public)")
				return
			}
			guard let response = response as? HTTPURLResponse else {
				logger.error("Received non-HTTP response to \(request, privacy: .public): \(String(describing: response), privacy: .public)")
				return
			}
			if (response.statusCode >= 200 && response.statusCode < 300) {
				if let data = data, data.count > 0 {
					// logger.info("Received \(response.statusCode) response with \(data.count) byte body")
					handler?(response.statusCode, data)
				} else {
					// logger.info("Received \(response.statusCode) response with empty body")
					handler?(response.statusCode, Data())
				}
			} else {
				if response.statusCode == 404 {
					logger.error("No such route: \(String(describing: request.httpMethod)) \(String(describing: request.url))")
					handler?(response.statusCode, Data())
				} else if let data = data, data.count > 0 {
					// if let message = String(data: data, encoding: .utf8) {
					// 	logger.error("Received \(response.statusCode, privacy: .public) response with message: \(message, privacy: .public)")
					// } else {
					// 	logger.error("Received \(response.statusCode, privacy: .public) reponse with non-UTF8 body: \(String(describing: data), privacy: .public)")
					// }
					handler?(response.statusCode, data)
				} else {
					// logger.error("Received \(response.statusCode, privacy: .public) response with no body")
					handler?(response.statusCode, Data())
				}
			}
		}
		// logger.info("Executing \(request.httpMethod!) \(request.url!)")
		task.resume()
		return task
	}
}
