// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import AVFAudio
import SwiftUI
import UserNotifications

/// build information
#if targetEnvironment(simulator)
let platformInfo = "simulator"
#elseif targetEnvironment(macCatalyst)
let platformInfo = "mac"
#else
let platformInfo = UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad"
#endif
let versionInfo = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "??"
let buildInfo = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "??"
#if DEBUG
let versionString = "\(versionInfo).\(Int(buildInfo.suffix(4))!)β"
#else
let versionString = "\(versionInfo).\(Int(buildInfo.suffix(4))!)"
#endif

/// global strings and URLs
let connectingLiveText = "This is where the line being typed by the whisperer will appear in real time... "
let connectingPastText = """
    This is where lines will move after the whisperer hits return.
    The most recent line will be on the bottom.
    """
let website = "https://whisper-project.github.io/client.swift"
let aboutSite = URL(string: website)!
let supportSite = URL(string: "\(website)/support.html")!
let instructionSite = URL(string: "\(website)/instructions.html")!
let settingsUrl = URL(string: UIApplication.openSettingsURLString)!

/// global constants for light/dark mode
let lightLiveTextColor = Color(.black)
let darkLiveTextColor = Color(.white)
let lightLiveBorderColor = Color(.black)
let darkLiveBorderColor = Color(.white)
let lightPastTextColor = Color(.darkGray)
let darkPastTextColor = Color(.lightGray)
let lightPastBorderColor = Color(.darkGray)
let darkPastBorderColor = Color(.lightGray)

/// global constants for relative view sizes
let liveTextFifths = UIDevice.current.userInterfaceIdiom == .phone ? 2.0 : 1.0
let pastTextProportion = (5.0 - liveTextFifths)/5.0
let liveTextProportion = liveTextFifths/5.0

/// global constants for platform differentiation
#if targetEnvironment(macCatalyst)
    let sidePad = CGFloat(5)
    let innerPad = CGFloat(5)
    let listenViewTopPad = CGFloat(15)
    let whisperViewTopPad = CGFloat(15)
    let listenViewBottomPad = CGFloat(5)
    let whisperViewBottomPad = CGFloat(15)
#else   // iOS
    let sidePad = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(5) : CGFloat(10)
    let innerPad = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(5) : CGFloat(10)
    let listenViewTopPad = CGFloat(0)
    let whisperViewTopPad = CGFloat(0)
    let listenViewBottomPad = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(5) : CGFloat(5)
    let whisperViewBottomPad = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(5) : CGFloat(15)
#endif

/// global timeouts
let listenerAdTime = TimeInterval(2)    // seconds of listener advertising for whisperers
let listenerWaitTime = TimeInterval(2)  // seconds of Bluetooth listener search before checking the internet
let whispererAdTime = TimeInterval(2)   // seconds of whisperer advertising to listeners

/// logging
import os
let logger = Logger()


@main
struct whisperApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

	@StateObject private var orientationInfo: OrientationInfo = .init()

    var body: some Scene {
        WindowGroup {
			RootView()
				.environmentObject(orientationInfo)
        }
		.handlesExternalEvents(matching: [PreferenceData.publisherUrlEventMatchString])

		WindowGroup(for: ListenConversation.self) { $conversation in
			LinkView(conversation: conversation)
				.environmentObject(orientationInfo)
		}
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
		PreferenceData.resetSecretsIfServerHasChanged()
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        } catch (let err) {
			logger.error("Failed to set audio session category: \(err, privacy: .public)")
        }
        logLifecycle("Registering for remote notifications")
        application.registerForRemoteNotifications()
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        logger.info("Received APNs token")
        let value: [String: Any] = [
            "clientId": PreferenceData.clientId,
            "token": deviceToken.base64EncodedString(),
            "userName": UserProfile.shared.username,
			"profileId": UserProfile.shared.id,
            "lastSecret": PreferenceData.lastClientSecret(),
            "appInfo": "\(platformInfo)|\(versionString)",
			"isPresenceLogging": PreferenceData.doPresenceLogging ? 1 : 0,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: value) else {
            fatalError("Can't encode body for device token call")
        }
        guard let url = URL(string: PreferenceData.whisperServer + "/api/v2/apnsToken") else {
            fatalError("Can't create URL for device token call")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            guard error == nil else {
				logAnomaly("Failed to post APNs token: \(String(describing: error))")
                return
            }
            guard let response = response as? HTTPURLResponse else {
				logAnomaly("Received non-HTTP response on APNs token post: \(String(describing: response))")
                return
            }
			if response.statusCode == 201 || response.statusCode == 204 {
                logger.info("Successful post of APNs token")
				if response.statusCode == 201 {
					logLifecycle("Server reponse forces reset of client secret and turns on packet logging")
					// Our secret has gone out of sync with server, it will create a new one
					// and post it to us.  Until that happens, we need to use our last
					// secret because the server doesn't know the current secret.
					PreferenceData.resetClientSecret()
					// Whenever we get a new secret, we start logging packets to the server
					// for debugging purposes.  It will tell us to stop when it wants to.
					PreferenceData.doPresenceLogging = true
				}
                return
            }
			logAnomaly("Received unexpected response on APNs token post: \(response.statusCode)")
            guard let data = data,
                  let body = try? JSONSerialization.jsonObject(with: data),
                  let obj = body as? [String:String] else {
				logAnomaly("Can't deserialize APNs token post response body: \(String(describing: data))")
                return
            }
			logAnomaly("Response body of failed APNs token post: \(obj)")
        }
        logger.info("Posting APNs token to whisper-server")
        task.resume()
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
		logAnomaly("Failed to get APNs token: \(error)")
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        logger.info("Received APNs background notification")
        if let value = userInfo["secret"], let secret = value as? String {
            logger.info("Succesfully saved data from background notification")
            PreferenceData.updateClientSecret(secret)
            let value = [
                "clientId": PreferenceData.clientId,
                "lastSecret": PreferenceData.lastClientSecret()
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: value) else {
                fatalError("Can't encode body for notification confirmation call")
            }
            guard let url = URL(string: PreferenceData.whisperServer + "/api/v2/apnsReceivedNotification") else {
                fatalError("Can't create URL for notification confirmation call")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                guard error == nil else {
                    logAnomaly("Failed to post notification confirmation: \(String(describing: error))")
					completionHandler(.failed)
					return
                }
                guard let response = response as? HTTPURLResponse else {
                    logAnomaly("Received non-HTTP response on notification confirmation: \(String(describing: response))")
					completionHandler(.failed)
					return
                }
                if response.statusCode == 204 {
                    logger.info("Successful post of notification confirmation")
                    completionHandler(.newData)
                    return
                }
				logAnomaly("Received unexpected response on notification confirmation post: \(response.statusCode)")
                completionHandler(.failed)
            }
            logger.info("Posting notification confirmation to whisper-server")
            task.resume()
        } else {
			logAnomaly("Background notification has unexpected data: \(String(describing: userInfo))")
            completionHandler(.failed)
        }
    }

	func applicationWillTerminate(_ application: UIApplication) {
		logLifecycle("App is terminating")
		let shared = AppStatus.shared
		shared.appIsQuitting = true
	}

	func application(_ application: UIApplication, configurationForConnecting: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
		let config = UISceneConfiguration(name: nil, sessionRole: .windowApplication)
		config.delegateClass = SceneDelegate.self
		return config
	}

	func application(_ application: UIApplication, didDiscardSceneSessions: Set<UISceneSession>) {
		for session in didDiscardSceneSessions {
			if let delegate = session.scene?.delegate as? SceneDelegate {
				logLifecycle("Discarded scene \(delegate.id)")
				PreferenceData.clearSceneState(delegate.id)
			}
		}
	}
}

class SceneDelegate: UIResponder, ObservableObject, UIWindowSceneDelegate {
	@Published var id: String = ""

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options _ignore: UIScene.ConnectionOptions) {
		id = session.persistentIdentifier
		logLifecycle("Connected scene \(id)")
	}

	func sceneDidDisconnect(_ scene: UIScene) {
		logLifecycle("Disconnected scene \(id)")
		var newQuit = AppStatus.shared.sceneQuit
		newQuit[id] = true
		AppStatus.shared.sceneQuit = newQuit
	}

	func sceneDidBecomeActive(_ scene: UIScene) {
		logger.debug("Activated scene \(self.id, privacy: .public)")
	}

	func sceneDidBecomeInactive(_ scene: UIScene) {
		logger.debug("Deactivated scene \(self.id, privacy: .public)")
	}

	func sceneDidEnterBackground(_ scene: UIScene) {
		logger.debug("Backgrounded scene \(self.id, privacy: .public)")
	}
}

// following code from https://stackoverflow.com/a/66394826/558006
func restartApplication() {
	logLifecycle("User is requesting restart of the app")

	let content = UNMutableNotificationContent()
	content.title = "Whisper app is ready to launch"
	content.body = "Tap to open the application"
	content.sound = UNNotificationSound.default
	let localUserInfo: [AnyHashable : Any] = ["pushType": "restart"]
	content.userInfo = localUserInfo
	let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
	let identifier = "org.whisper-project.client.swift.restart"
	let request = UNNotificationRequest.init(identifier: identifier, content: content, trigger: trigger)
	let center = UNUserNotificationCenter.current()
	center.add(request)

	exit(0)
}

final class AppStatus: ObservableObject {
	static var shared: AppStatus = .init()

	@Published var appIsQuitting: Bool = false
	@Published var sceneQuit: [String: Bool] = [:]
}
