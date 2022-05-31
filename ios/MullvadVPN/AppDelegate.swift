//
//  AppDelegate.swift
//  MullvadVPN
//
//  Created by pronebird on 19/03/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import UIKit
import BackgroundTasks
import StoreKit
import UserNotifications
import Logging

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    #if targetEnvironment(simulator)
    private let simulatorTunnelProvider = SimulatorTunnelProviderHost()
    #endif

    private var logger: Logger?

    // An instance of scene delegate used on iOS 12 or earlier.
    private var sceneDelegate: SceneDelegate?

    // MARK: - Application lifecycle

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Setup logging
        initLoggingSystem(bundleIdentifier: Bundle.main.bundleIdentifier!)

        logger = Logger(label: "AppDelegate")

        #if targetEnvironment(simulator)
        // Configure mock tunnel provider on simulator
        SimulatorTunnelProvider.shared.delegate = simulatorTunnelProvider
        #endif

        if #available(iOS 13.0, *) {
            // Register background tasks on iOS 13
            registerBackgroundTasks()
        } else {
            // Set background refresh interval on iOS 12
            application.setMinimumBackgroundFetchInterval(
                ApplicationConfiguration.minimumBackgroundFetchInterval
            )
        }

        // Setup payments handling.
        AppStorePaymentManager.shared.delegate = self
        AppStorePaymentManager.shared.addPaymentObserver(TunnelManager.shared)

        // Setup notifications.
        NotificationManager.shared.notificationProviders = [
            AccountExpiryNotificationProvider(),
            TunnelErrorNotificationProvider()
        ]

        // Initialize tunnel manager.
        TunnelManager.shared.loadConfiguration { error in
            dispatchPrecondition(condition: .onQueue(.main))

            if let error = error {
                // TODO: avoid throwing fatal error and show the problem report UI instead.
                fatalError(error.displayChain(message: "Failed to load tunnel configuration."))
            }

            NotificationManager.shared.updateNotifications()
            AppStorePaymentManager.shared.startPaymentQueueMonitoring()
        }

        // Assign user notification center delegate.
        UNUserNotificationCenter.current().delegate = self

        if #available(iOS 13, *) {
            return true
        } else {
            sceneDelegate = SceneDelegate()
            sceneDelegate?.setupScene(windowFactory: ClassicWindowFactory())

            return true
        }
    }

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        logger?.info("Start background refresh")

        var addressCacheFetchResult: UIBackgroundFetchResult?
        var relaysFetchResult: UIBackgroundFetchResult?
        var rotatePrivateKeyFetchResult: UIBackgroundFetchResult?

        let operationQueue = OperationQueue()

        let updateAddressCacheOperation = AsyncBlockOperation(dispatchQueue: .main) { operation in
            let handle = AddressCache.Tracker.shared.updateEndpoints { completion in
                addressCacheFetchResult = completion.backgroundFetchResult
                operation.finish()
            }

            operation.addCancellationBlock {
                handle.cancel()
            }
        }

        let updateRelaysOperation = AsyncBlockOperation(dispatchQueue: .main) { operation in
            let handle = RelayCache.Tracker.shared.updateRelays { completion in
                relaysFetchResult = completion.backgroundFetchResult
                operation.finish()
            }

            operation.addCancellationBlock {
                handle.cancel()
            }
        }

        let rotatePrivateKeyOperation = AsyncBlockOperation(dispatchQueue: .main) { operation in
            let handle = TunnelManager.shared.rotatePrivateKey(forceRotate: false) { completion in
                rotatePrivateKeyFetchResult = completion.backgroundFetchResult { $0 }
                operation.finish()
            }

            operation.addCancellationBlock {
                handle.cancel()
            }
        }

        rotatePrivateKeyOperation.addDependencies([
            updateRelaysOperation,
            updateAddressCacheOperation
        ])

        let backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Background refresh"
        ) {
            operationQueue.cancelAllOperations()
        }

        let fetchOperations = [
            updateAddressCacheOperation,
            updateRelaysOperation,
            rotatePrivateKeyOperation
        ]

        let completionOperation = BlockOperation {
            let operationResults = [
                addressCacheFetchResult,
                relaysFetchResult,
                rotatePrivateKeyFetchResult
            ].compactMap { $0 }

            let initialResult = operationResults.first ?? .failed
            let backgroundFetchResult = operationResults
                .reduce(initialResult) { partialResult, other in
                    return partialResult.combine(with: other)
                }

            self.logger?.info("Finish background refresh with \(backgroundFetchResult)")

            completionHandler(backgroundFetchResult)

            UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        }

        completionOperation.addDependencies(fetchOperations)

        operationQueue.addOperations(fetchOperations, waitUntilFinished: false)
        OperationQueue.main.addOperation(completionOperation)
    }

    // MARK: - UISceneSession lifecycle

    @available(iOS 13.0, *)
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        let sceneConfiguration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        sceneConfiguration.delegateClass = SceneDelegate.self

        return sceneConfiguration
    }

    @available(iOS 13.0, *)
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

    // MARK: - Background tasks

    @available(iOS 13, *)
    private func registerBackgroundTasks() {
        registerAppRefreshTask()
        registerAddressCacheUpdateTask()
        registerKeyRotationTask()
    }

    @available(iOS 13.0, *)
    private func registerAppRefreshTask() {
        let isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ApplicationConfiguration.appRefreshTaskIdentifier,
            using: nil
        ) { task in
            let handle = RelayCache.Tracker.shared.updateRelays { completion in
                task.setTaskCompleted(success: completion.isSuccess)
            }

            task.expirationHandler = {
                handle.cancel()
            }

            self.scheduleAppRefreshTask()
        }

        if isRegistered {
            logger?.debug("Registered app refresh task.")
        } else {
            logger?.error("Failed to register app refresh task.")
        }
    }

    @available(iOS 13.0, *)
    private func registerKeyRotationTask() {
        let isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ApplicationConfiguration.privateKeyRotationTaskIdentifier,
            using: nil
        ) { task in
            let handle = TunnelManager.shared.rotatePrivateKey(forceRotate: false) { completion in
                self.scheduleKeyRotationTask()

                task.setTaskCompleted(success: completion.isSuccess)
            }

            task.expirationHandler = {
                handle.cancel()
            }
        }

        if isRegistered {
            logger?.debug("Registered private key rotation task.")
        } else {
            logger?.error("Failed to register private key rotation task.")
        }
    }

    @available(iOS 13.0, *)
    private func registerAddressCacheUpdateTask() {
        let isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ApplicationConfiguration.addressCacheUpdateTaskIdentifier,
            using: nil
        ) { task in
            let handle = AddressCache.Tracker.shared.updateEndpoints { completion in
                self.scheduleAddressCacheUpdateTask()

                task.setTaskCompleted(success: completion.isSuccess)
            }

            task.expirationHandler = {
                handle.cancel()
            }
        }

        if isRegistered {
            logger?.debug("Registered address cache update task.")
        } else {
            logger?.error("Failed to register address cache update task.")
        }
    }

    @available(iOS 13.0, *)
    func scheduleBackgroundTasks() {
        scheduleAppRefreshTask()
        scheduleKeyRotationTask()
        scheduleAddressCacheUpdateTask()
    }

    @available(iOS 13.0, *)
    private func scheduleAppRefreshTask() {
        do {
            let date = RelayCache.Tracker.shared.getNextUpdateDate()

            let request = BGAppRefreshTaskRequest(
                identifier: ApplicationConfiguration.appRefreshTaskIdentifier
            )
            request.earliestBeginDate = date

            logger?.debug("Schedule app refresh task on \(date.logFormatDate()).")

            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger?.error(
                chainedError: AnyChainedError(error),
                message: "Could not schedule app refresh task."
            )
        }
    }

    @available(iOS 13.0, *)
    private func scheduleKeyRotationTask() {
        do {
            guard let date = TunnelManager.shared.getNextKeyRotationDate() else {
                return
            }

            let request = BGProcessingTaskRequest(
                identifier: ApplicationConfiguration.privateKeyRotationTaskIdentifier
            )
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = date

            logger?.debug("Schedule key rotation task on \(date.logFormatDate()).")

            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger?.error(
                chainedError: AnyChainedError(error),
                message: "Could not schedule private key rotation task."
            )
        }
    }

    @available(iOS 13.0, *)
    private func scheduleAddressCacheUpdateTask() {
        do {
            let date = AddressCache.Tracker.shared.nextScheduleDate()

            let request = BGProcessingTaskRequest(
                identifier: ApplicationConfiguration.addressCacheUpdateTaskIdentifier
            )
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = date

            logger?.debug("Schedule address cache update task at \(date.logFormatDate()).")

            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger?.error(
                chainedError: AnyChainedError(error),
                message: "Could not schedule address cache update task."
            )
        }
    }
}

// MARK: - AppStorePaymentManagerDelegate

extension AppDelegate: AppStorePaymentManagerDelegate {

    func appStorePaymentManager(_ manager: AppStorePaymentManager,
                                didRequestAccountTokenFor payment: SKPayment) -> String?
    {
        // Since we do not persist the relation between the payment and account token between the
        // app launches, we assume that all successful purchases belong to the active account token.
        return TunnelManager.shared.accountNumber
    }

}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == accountExpiryNotificationIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier
        {
            if #available(iOS 13.0, *) {
                // FIXME: scene may not be connected yet.
                let sceneDelegate = UIApplication.shared.connectedScenes
                    .first?.delegate as? SceneDelegate

                sceneDelegate?.showUserAccount()
            } else {
                sceneDelegate?.showUserAccount()
            }
        }

        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) {
            completionHandler([.list])
        } else {
            completionHandler([])
        }
    }

}
