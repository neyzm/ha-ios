import Alamofire
import AVFoundation
import AVKit
import CoreLocation
import HAKit
import KeychainAccess
import MBProgressHUD
import PromiseKit
import Shared
import SwiftMessages
import SwiftUI
import UIKit
@preconcurrency import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    var webView: WKWebView!

    let server: Server

    private var urlObserver: NSKeyValueObservation?
    private var tokens = [HACancellable]()

    private let refreshControl = UIRefreshControl()
    private let leftEdgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer
    private let rightEdgeGestureRecognizer: UIScreenEdgePanGestureRecognizer

    let webViewExternalMessageHandler = WebViewExternalMessageHandler.build()
    private var emptyStateView: UIView?
    private let emptyStateTransitionDuration: TimeInterval = 0.3

    private var initialURL: URL?
    private var statusBarButtonsStack: UIStackView?
    private var lastNavigationWasServerError = false
    private var reconnectBackgroundTimer: Timer? {
        willSet {
            if reconnectBackgroundTimer != newValue {
                reconnectBackgroundTimer?.invalidate()
            }
        }
    }

    /// Defer showing the empty state until disconnected for 4 seconds (var used in
    /// WebViewControllerProtocol+Implementation )
    var emptyStateTimer: Timer?

    private var underlyingPreferredStatusBarStyle: UIStatusBarStyle = .lightContent

    override var prefersStatusBarHidden: Bool {
        Current.settingsStore.fullScreen
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        Current.settingsStore.fullScreen
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        underlyingPreferredStatusBarStyle
    }

    init(server: Server, shouldLoadImmediately: Bool = false) {
        self.server = server
        self.leftEdgePanGestureRecognizer = with(UIScreenEdgePanGestureRecognizer()) {
            $0.edges = .left
        }
        self.rightEdgeGestureRecognizer = with(UIScreenEdgePanGestureRecognizer()) {
            $0.edges = .right
        }

        super.init(nibName: nil, bundle: nil)

        userActivity = with(NSUserActivity(activityType: "\(AppConstants.BundleID).frontend")) {
            $0.isEligibleForHandoff = true
        }

        leftEdgePanGestureRecognizer.addTarget(self, action: #selector(screenEdgeGestureRecognizerAction(_:)))
        rightEdgeGestureRecognizer.addTarget(self, action: #selector(screenEdgeGestureRecognizerAction(_:)))

        if shouldLoadImmediately {
            loadViewIfNeeded()
            loadActiveURLIfNeeded()
        }
    }

    convenience init?(restoring: WebViewRestorationType?, shouldLoadImmediately: Bool = false) {
        if let server = restoring?.server ?? Current.servers.all.first {
            self.init(server: server)
        } else {
            return nil
        }

        self.initialURL = restoring?.initialURL
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.urlObserver = nil
        self.tokens.forEach { $0.cancel() }
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        webViewExternalMessageHandler.webViewController = self

        becomeFirstResponder()

        observeConnectionNotifications()

        let statusBarView = setupStatusBarView()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let userContentController = setupUserContentController()

        guard let wsBridgeJSPath = Bundle.main.path(forResource: "WebSocketBridge", ofType: "js"),
              let wsBridgeJS = try? String(contentsOfFile: wsBridgeJSPath) else {
            fatalError("Couldn't load WebSocketBridge.js for injection to WKWebView!")
        }

        userContentController.addUserScript(WKUserScript(
            source: wsBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))

        userContentController.addUserScript(.init(
            source: """
                window.addEventListener("error", (e) => {
                    window.webkit.messageHandlers.logError.postMessage({
                        "message": JSON.stringify(e.message),
                        "filename": JSON.stringify(e.filename),
                        "lineno": JSON.stringify(e.lineno),
                        "colno": JSON.stringify(e.colno),
                    });
                });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        config.userContentController = userContentController
        config.applicationNameForUserAgent = HomeAssistantAPI.applicationNameForUserAgent
        config.defaultWebpagePreferences.preferredContentMode = Current.isCatalyst ? .desktop : .mobile

        webView = WKWebView(frame: view!.frame, configuration: config)
        webView.isOpaque = false
        view!.addSubview(webView)

        setupGestures(numberOfTouchesRequired: 2)
        setupGestures(numberOfTouchesRequired: 3)
        setupEgdeGestures()
        setupURLObserver()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        setupWebViewConstraints(statusBarView: statusBarView)
        setupPullToRefresh()
        setupEmptyState()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateWebViewSettingsForNotification),
            name: SettingsStore.webViewRelatedSettingDidChange,
            object: nil
        )
        updateWebViewSettings(reason: .initial)
        styleUI()
        getLatestConfig()

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        postOnboardingNotificationPermission()
    }

    // Workaround for webview rotation issues: https://github.com/Telerik-Verified-Plugins/WKWebView/pull/263
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.webView?.setNeedsLayout()
            self.webView?.layoutIfNeeded()
        }, completion: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadActiveURLIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        userActivity?.resignCurrent()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            webView.evaluateJavaScript("notifyThemeColors()", completionHandler: nil)
        }
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            let action = Current.settingsStore.gestures[.shake] ?? .openDebug
            handleGestureAction(action)
        }
    }

    // MARK: - Private

    private func observeConnectionNotifications() {
        for name: Notification.Name in [
            HomeAssistantAPI.didConnectNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(connectionInfoDidChange),
                name: name,
                object: nil
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleReconnectBackgroundTimer),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        tokens.append(server.observe { [weak self] _ in
            self?.connectionInfoDidChange()
        })
    }

    private func setupPullToRefresh() {
        if !Current.isCatalyst {
            // refreshing is handled by menu/keyboard shortcuts
            refreshControl.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
            webView.scrollView.addSubview(refreshControl)
            webView.scrollView.bounces = true
        }
    }

    private func setupEmptyState() {
        let emptyState = WebViewEmptyStateWrapperView { [weak self] in
            self?.hideEmptyState()
            self?.webView.reload()
        } settingsAction: { [weak self] in
            self?.showSettingsViewController()
        } dismissAction: { [weak self] in
            self?.hideEmptyState()
        }

        view.addSubview(emptyState)

        emptyState.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            emptyState.leftAnchor.constraint(equalTo: view.leftAnchor),
            emptyState.rightAnchor.constraint(equalTo: view.rightAnchor),
            emptyState.topAnchor.constraint(equalTo: view.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        emptyState.alpha = 0
        emptyStateView = emptyState
    }

    func showEmptyState() {
        UIView.animate(withDuration: emptyStateTransitionDuration, delay: 0, options: .curveEaseInOut, animations: {
            self.emptyStateView?.alpha = 1
        }, completion: nil)
    }

    func hideEmptyState() {
        UIView.animate(withDuration: emptyStateTransitionDuration, delay: 0, options: .curveEaseInOut, animations: {
            self.emptyStateView?.alpha = 0
        }, completion: nil)
    }

    private func setupWebViewConstraints(statusBarView: UIView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        webView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true
        webView.topAnchor.constraint(equalTo: statusBarView.bottomAnchor).isActive = true
        webView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    private func setupURLObserver() {
        urlObserver = webView.observe(\.url) { [weak self] webView, _ in
            guard let self else { return }

            guard let currentURL = webView.url?.absoluteString.replacingOccurrences(of: "?external_auth=1", with: ""),
                  let cleanURL = URL(string: currentURL), let scheme = cleanURL.scheme else {
                return
            }

            guard ["http", "https"].contains(scheme) else {
                Current.Log.warning("Was going to provide invalid URL to NSUserActivity! \(currentURL)")
                return
            }

            userActivity?.webpageURL = cleanURL
            userActivity?.userInfo = [
                RestorableStateKey.lastURL.rawValue: cleanURL,
                RestorableStateKey.server.rawValue: server.identifier.rawValue,
            ]
            userActivity?.becomeCurrent()
        }
    }

    private func setupGestures(numberOfTouchesRequired: Int) {
        let gestures = [.left, .right, .up, .down].map { (direction: UISwipeGestureRecognizer.Direction) in
            let gesture = UISwipeGestureRecognizer()
            gesture.numberOfTouchesRequired = numberOfTouchesRequired
            gesture.direction = direction
            gesture.addTarget(self, action: #selector(swipe(_:)))
            gesture.delegate = self
            return gesture
        }

        for gesture in gestures {
            view.addGestureRecognizer(gesture)
        }
    }

    private func setupEgdeGestures() {
        webView.addGestureRecognizer(leftEdgePanGestureRecognizer)
        webView.addGestureRecognizer(rightEdgeGestureRecognizer)
    }

    private func setupUserContentController() -> WKUserContentController {
        let userContentController = WKUserContentController()
        let safeScriptMessageHandler = SafeScriptMessageHandler(delegate: self)
        userContentController.add(safeScriptMessageHandler, name: "getExternalAuth")
        userContentController.add(safeScriptMessageHandler, name: "revokeExternalAuth")
        userContentController.add(safeScriptMessageHandler, name: "externalBus")
        userContentController.add(safeScriptMessageHandler, name: "updateThemeColors")
        userContentController.add(safeScriptMessageHandler, name: "logError")
        return userContentController
    }

    private func setupStatusBarView() -> UIView {
        let statusBarView = UIView()
        statusBarView.tag = 111

        view.addSubview(statusBarView)
        statusBarView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            statusBarView.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarView.leftAnchor.constraint(equalTo: view.leftAnchor),
            statusBarView.rightAnchor.constraint(equalTo: view.rightAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])

        if Current.isCatalyst {
            setupStatusBarButtons(statusBarView: statusBarView)
        }

        return statusBarView
    }

    private func setupStatusBarButtons(statusBarView: UIView) {
        let picker = UIButton(type: .system)
        picker.setTitle(server.info.name, for: .normal)
        picker.translatesAutoresizingMaskIntoConstraints = false

        let menuActions = Current.servers.all.map { server in
            UIAction(title: server.info.name, handler: { [weak self] _ in
                self?.openServer(server)
            })
        }

        // Using UIMenu since UIPickerView is not available on Catalyst
        picker.menu = UIMenu(title: L10n.WebView.ServerSelection.title, children: menuActions)
        picker.showsMenuAsPrimaryAction = true

        if let statusBarButtonsStack {
            statusBarButtonsStack.removeFromSuperview()
            self.statusBarButtonsStack = nil
        }

        let arrangedSubviews: [UIView] = Current.servers.all.count > 1 ? [picker] : []

        let stackView = UIStackView(arrangedSubviews: arrangedSubviews)
        stackView.axis = .horizontal
        stackView.spacing = Spaces.one

        statusBarView.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let openInSafariButton = UIButton(type: .custom)
        let image = UIImage(resource: .compass).scaledToSize(.init(width: 7, height: 7))
            .withTintColor(.haPrimary)
        openInSafariButton.setImage(image, for: .normal)
        openInSafariButton.backgroundColor = .white
        openInSafariButton.tintColor = .white
        openInSafariButton.layer.cornerRadius = 6
        openInSafariButton.layer.shadowColor = UIColor.black.cgColor
        openInSafariButton.layer.shadowRadius = 0.5
        openInSafariButton.layer.shadowOpacity = 0.7
        openInSafariButton.layer.shadowOffset = .init(width: 0, height: 0)
        openInSafariButton.layer.masksToBounds = false
        openInSafariButton.addTarget(self, action: #selector(openServerInSafari), for: .touchUpInside)
        statusBarView.addSubview(openInSafariButton)
        openInSafariButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stackView.rightAnchor.constraint(equalTo: statusBarView.rightAnchor, constant: -Spaces.half),
            stackView.topAnchor.constraint(equalTo: statusBarView.topAnchor, constant: Spaces.half),
            openInSafariButton.leftAnchor.constraint(equalTo: statusBarView.leftAnchor, constant: 68),
            openInSafariButton.topAnchor.constraint(equalTo: statusBarView.topAnchor, constant: 8),
            openInSafariButton.widthAnchor.constraint(equalToConstant: 12),
            openInSafariButton.heightAnchor.constraint(equalToConstant: 12),
        ])
        statusBarButtonsStack = stackView
    }

    private func openServer(_ server: Server) {
        Current.sceneManager.webViewWindowControllerPromise.done { controller in
            controller.open(server: server)
        }
    }

    func styleUI() {
        precondition(isViewLoaded && webView != nil)

        let cachedColors = ThemeColors.cachedThemeColors(for: traitCollection)

        webView?.backgroundColor = cachedColors[.primaryBackgroundColor]
        webView?.scrollView.backgroundColor = cachedColors[.primaryBackgroundColor]

        if let statusBarView = view.viewWithTag(111) {
            if server.info.version < .canUseAppThemeForStatusBar {
                statusBarView.backgroundColor = cachedColors[.appHeaderBackgroundColor]
            } else {
                statusBarView.backgroundColor = cachedColors[.appThemeColor]
            }
        }

        refreshControl.tintColor = cachedColors[.primaryColor]

        let headerBackgroundIsLight = cachedColors[.appThemeColor].isLight
        underlyingPreferredStatusBarStyle = headerBackgroundIsLight ? .darkContent : .lightContent

        setNeedsStatusBarAppearanceUpdate()
    }

    private func swiftMessagesConfig() -> SwiftMessages.Config {
        var config = SwiftMessages.Config()

        config.presentationContext = .viewController(self)
        config.duration = .forever
        config.presentationStyle = .bottom
        config.dimMode = .gray(interactive: true)
        config.dimModeAccessibilityLabel = L10n.cancelLabel

        return config
    }

    private func showNoActiveURLError() {
        Current.Log.info("Showing noActiveURLError")
        webView.scrollView.refreshControl?.endRefreshing()
        guard !(overlayedController is NoActiveURLViewController) else { return }
        presentOverlayController(controller: NoActiveURLViewController(server: server), animated: true)
    }

    private func getLatestConfig() {
        _ = Current.api(for: server)?.getConfig()
    }

    private func showActionAutomationEditorNotAvailable() {
        let alert = UIAlertController(
            title: L10n.Alerts.ActionAutomationEditor.Unavailable.title,
            message: L10n.Alerts.ActionAutomationEditor.Unavailable.body,
            preferredStyle: .alert
        )
        alert.addAction(.init(title: L10n.okLabel, style: .default))
        present(alert, animated: true)
    }

    private func updateWebViewSettings(reason: WebViewSettingsUpdateReason) {
        Current.Log.info("updating web view settings for \(reason)")

        // iOS 14's `pageZoom` property is almost this, but not quite - it breaks the layout as well
        // This is quasi-private API that has existed since pre-iOS 10, but the implementation
        // changed in iOS 12 to be like the +/- zoom buttons in Safari, which scale content without
        // resizing the scrolling viewport.
        let viewScale = Current.settingsStore.pageZoom.viewScaleValue
        Current.Log.info("setting view scale to \(viewScale)")
        webView.setValue(viewScale, forKey: "viewScale")

        if !Current.isCatalyst {
            let zoomValue = Current.settingsStore.pinchToZoom ? "true" : "false"
            webView.evaluateJavaScript("setOverrideZoomEnabled(\(zoomValue))", completionHandler: nil)
        }

        if reason == .settingChange {
            setNeedsStatusBarAppearanceUpdate()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    // MARK: - @objc

    @objc private func connectionInfoDidChange() {
        DispatchQueue.main.async { [self] in
            loadActiveURLIfNeeded()
        }
    }

    @objc private func loadActiveURLIfNeeded() {
        guard let webviewURL = server.info.connection.webviewURL() else {
            Current.Log.info("not loading, no url")
            showNoActiveURLError()
            return
        }

        guard webView.url == nil || webView.url?.baseIsEqual(to: webviewURL) == false else {
            // we also tell the webview -- maybe it failed to connect itself? -- to refresh if needed
            webView.evaluateJavaScript("checkForMissingHassConnectionAndReload()", completionHandler: nil)
            return
        }

        guard UIApplication.shared.applicationState != .background else {
            Current.Log.info("not loading, in background")
            return
        }

        // if we aren't showing a url or it's an incorrect url, update it -- otherwise, leave it alone
        let request: URLRequest

        if Current.settingsStore.restoreLastURL,
           let initialURL, initialURL.baseIsEqual(to: webviewURL) {
            Current.Log.info("restoring initial url path: \(initialURL.path)")
            request = URLRequest(url: initialURL)
        } else {
            Current.Log.info("loading default url path: \(webviewURL.path)")
            request = URLRequest(url: webviewURL)
        }

        webView.load(request)
    }

    @objc private func refresh() {
        // called via menu/keyboard shortcut too
        if let webviewURL = server.info.connection.webviewURL() {
            if webView.url?.baseIsEqual(to: webviewURL) == true, !lastNavigationWasServerError {
                webView.reload()
            } else {
                webView.load(URLRequest(url: webviewURL))
            }
        } else {
            showNoActiveURLError()
        }
    }

    @objc private func swipe(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }
        let action = Current.settingsStore.gestures.getAction(for: gesture, numberOfTouches: gesture.numberOfTouches)
        handleGestureAction(action)
    }

    @objc private func screenEdgeGestureRecognizerAction(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }
        let gesture: AppGesture = gesture.edges == .left ? .swipeRight : .swipeLeft
        let action = Current.settingsStore.gestures[gesture] ?? .none
        handleGestureAction(action)
    }

    @objc private func updateSensors() {
        // called via menu/keyboard shortcut too
        firstly {
            HomeAssistantAPI.manuallyUpdate(
                applicationState: UIApplication.shared.applicationState,
                type: .userRequested
            )
        }.catch { error in
            Current.Log.error("Error when updating sensors from WKWebView reload: \(error)")
        }
    }

    @objc func pullToRefresh(_ sender: UIRefreshControl) {
        refresh()
        updateSensors()
    }

    @objc func openSettingsView(_ sender: UIButton) {
        showSettingsViewController()
    }

    @objc private func openServerInSafari() {
        if let url = webView.url {
            guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return
            }
            // Remove external_auth=1 query item from URL
            urlComponents.queryItems = urlComponents.queryItems?.filter { $0.name != "external_auth" }

            if let url = urlComponents.url {
                UIApplication.shared.open(url)
            }
        }
    }

    @objc private func scheduleReconnectBackgroundTimer() {
        precondition(Thread.isMainThread)

        guard isViewLoaded, server.info.version >= .externalBusCommandRestart else { return }

        // On iOS 15, Apple switched to using NSURLSession's WebSocket implementation, which is pretty bad at detecting
        // any kind of networking failure. Even more troubling, it doesn't realize there's a failure due to background
        // so it spends dozens of seconds waiting for a connection reset externally.
        //
        // We work around this by detecting being in the background for long enough that it's likely the connection will
        // need to reconnect, anyway (similar to how we do it in HAKit). When this happens, we ask the frontend to
        // reset its WebSocket connection, thus eliminating the wait.
        //
        // It's likely this doesn't apply before iOS 15, but it may improve the reconnect timing there anyhow.

        reconnectBackgroundTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true,
            block: { [weak self] timer in
                if let self, Current.date().timeIntervalSince(timer.fireDate) > 30.0 {
                    webViewExternalMessageHandler.sendExternalBus(message: .init(command: "restart"))
                }

                if UIApplication.shared.applicationState == .active {
                    timer.invalidate()
                }
            }
        )
    }

    @objc private func updateWebViewSettingsForNotification() {
        updateWebViewSettings(reason: .settingChange)
    }

    func show(alert: ServerAlert) {
        Current.Log.info("showing alert \(alert)")

        var config = swiftMessagesConfig()
        config.eventListeners.append({ event in
            switch event {
            case .didHide:
                Current.serverAlerter.markHandled(alert: alert)
            default:
                break
            }
        })

        let view = MessageView.viewFromNib(layout: .messageView)
        view.configureTheme(
            backgroundColor: UIColor(red: 1.000, green: 0.596, blue: 0.000, alpha: 1.0),
            foregroundColor: .white
        )
        view.configureContent(
            title: nil,
            body: alert.message,
            iconImage: nil,
            iconText: nil,
            buttonImage: nil,
            buttonTitle: L10n.openLabel,
            buttonTapHandler: { _ in
                UIApplication.shared.open(alert.url, options: [:], completionHandler: nil)
                SwiftMessages.hide()
            }
        )

        SwiftMessages.show(config: config, view: view)
    }

    func showSwiftMessage(error: Error, duration: SwiftMessages.Duration = .seconds(seconds: 15)) {
        Current.Log.error(error)
        var config = swiftMessagesConfig()
        config.duration = duration

        let view = MessageView.viewFromNib(layout: .messageView)
        view.configureContent(
            title: L10n.Connection.Error.genericTitle,
            body: error.localizedDescription,
            iconImage: nil,
            iconText: nil,
            buttonImage: MaterialDesignIcons.helpCircleIcon.image(
                ofSize: .init(width: 35, height: 35),
                color: .haPrimary
            ),
            buttonTitle: nil,
            buttonTapHandler: { [weak self] _ in
                SwiftMessages.hide()
                guard let self else { return }
                presentOverlayController(
                    controller: UIHostingController(rootView: ConnectionErrorDetailsView(server: server, error: error)),
                    animated: true
                )
            }
        )
        view.titleLabel?.numberOfLines = 0
        view.bodyLabel?.numberOfLines = 0

        SwiftMessages.show(config: config, view: view)
    }

    func showReAuthPopup(serverId: String, code: Int) {
        guard serverId == server.identifier.rawValue else {
            return
        }
        var config = swiftMessagesConfig()
        config.duration = .forever
        let view = MessageView.viewFromNib(layout: .messageView)
        view.configureTheme(.warning)
        view.configureContent(
            title: L10n.Unauthenticated.Message.title,
            body: L10n.Unauthenticated.Message.body,
            iconImage: nil,
            iconText: nil,
            buttonImage: MaterialDesignIcons.cogIcon.image(
                ofSize: CGSize(width: 24, height: 24),
                color: .haPrimary
            ),
            buttonTitle: nil,
            buttonTapHandler: { [weak self] _ in
                self?.showSettingsViewController()
            }
        )
        view.titleLabel?.numberOfLines = 0
        view.bodyLabel?.numberOfLines = 0

        // Avoid retrying from Home Assistant UI since this is a dead end
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        showEmptyState()
        SwiftMessages.show(config: config, view: view)
    }

    func openDebug() {
        let controller = UIHostingController(rootView: AnyView(
            NavigationView {
                VStack {
                    HStack(spacing: Spaces.half) {
                        Text(verbatim: L10n.Settings.Debugging.ShakeDisclaimerOptional.title)
                        Toggle(isOn: .init(get: {
                            Current.settingsStore.gestures[.shake] == .openDebug
                        }, set: { newValue in
                            Current.settingsStore.gestures[.shake] = newValue ? .openDebug : HAGestureAction.none
                        }), label: { EmptyView() })
                    }
                    .padding()
                    .background(Color.haPrimary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusSizes.oneAndHalf))
                    .padding(Spaces.one)
                    DebugView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                CloseButton { [weak self] in
                                    self?.dismissOverlayController(animated: true, completion: nil)
                                }
                            }
                        }
                }
            }
        ))
        presentOverlayController(controller: controller, animated: true)
    }

    // MARK: - Public

    /// avoidUnecessaryReload Avoids reloading when the URL is the same as the current one
    public func open(inline url: URL, avoidUnecessaryReload: Bool = false) {
        loadViewIfNeeded()

        // these paths do not show frontend pages, and so we don't want to display them in our webview
        // otherwise the user will get stuck. e.g. /api is loaded by frigate to show video clips and images
        let ignoredPaths = [
            "/api",
            "/static",
            "/hacsfiles",
            "/local",
        ]

        if ignoredPaths.allSatisfy({ !url.path.hasPrefix($0) }) {
            if avoidUnecessaryReload, webView.url?.isEqualIgnoringQueryParams(to: url) == true {
                Current.Log
                    .info(
                        "Not reloading WebView when open(inline) was requested, URL is the same as current and avoidUnecessaryReload is true"
                    )
                return
            }
            webView.load(URLRequest(url: url))
        } else {
            openURLInBrowser(url, self)
        }
    }

    /// Used for OpenPage intent
    public func openPanel(_ url: URL) {
        loadViewIfNeeded()
        if #available(iOS 16.0, *),
           let webViewURL = webView.url,
           webViewURL.path().contains(url.path()) {
            Current.Log.info("Open page did not reload webview because path component matches current URL")
            return
        } else {
            if !navigate(path: url.path) {
                webView.load(URLRequest(url: url))
            }
        }
    }

    /// Uses external bus to navigate through frontend instead of loading the page from scratch using the web view
    /// Returns true if the navigation was successful
    private func navigate(path: String) -> Bool {
        guard server.info.version >= .canNavigateThroughFrontend else {
            Current.Log.warning("Cannot navigate through frontend, core version is too low")
            return false
        }
        webViewExternalMessageHandler.sendExternalBus(message: .init(
            command: WebViewExternalBusOutgoingMessage.navigate.rawValue,
            payload: [
                "path": path,
            ]
        ))
        return true
    }

    public func showSettingsViewController() {
        getLatestConfig()
        if Current.sceneManager.supportsMultipleScenes, Current.isCatalyst {
            Current.sceneManager.activateAnyScene(for: .settings)
        } else {
            let settingsView = SettingsViewController()
            settingsView.hidesBottomBarWhenPushed = true
            let navController = UINavigationController(rootViewController: settingsView)
            presentOverlayController(controller: navController, animated: true)
        }
    }

    public func openActionAutomationEditor(actionId: String) {
        guard server.info.version >= .externalBusCommandAutomationEditor else {
            showActionAutomationEditorNotAvailable()
            return
        }
        webViewExternalMessageHandler.sendExternalBus(message: .init(
            command: WebViewExternalBusOutgoingMessage.showAutomationEditor.rawValue,
            payload: [
                "config": [
                    "trigger": [
                        [
                            "platform": "event",
                            "event_type": "ios.action_fired",
                            "event_data": [
                                "actionID": actionId,
                            ],
                        ],
                    ],
                ],
            ]
        ))
    }
}

// MARK: - WebView

extension WebViewController {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        webViewExternalMessageHandler.stopImprovScanIfNeeded()
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let result = server.info.connection.evaluate(challenge)
        completionHandler(result.0, result.1)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            openURLInBrowser(navigationAction.request.url!, self)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        if let err = error as? URLError {
            if err.code != .cancelled {
                Current.Log.error("Failure during nav: \(err)")
            }

            if !error.isCancelled {
                showEmptyState()
                showSwiftMessage(error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        if let err = error as? URLError {
            if err.code != .cancelled {
                Current.Log.error("Failure during content load: \(error)")
            }

            if !error.isCancelled {
                showEmptyState()
                showSwiftMessage(error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()

        // in case the view appears again, don't reload
        initialURL = nil

        updateWebViewSettings(reason: .load)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        if #available(iOS 17.0, *) {
            let viewModel = DownloadManagerViewModel()
            let downloadManager = DownloadManagerView(viewModel: viewModel)
            let downloadController = UIHostingController(rootView: downloadManager)
            presentOverlayController(controller: downloadController, animated: true)
            download.delegate = viewModel
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        lastNavigationWasServerError = false

        guard navigationResponse.isForMainFrame else {
            // we don't need to modify the response if it's for a sub-frame
            decisionHandler(.allow)
            return
        }

        guard let httpResponse = navigationResponse.response as? HTTPURLResponse, httpResponse.statusCode >= 400 else {
            // not an error response, we don't need to inspect at all
            decisionHandler(.allow)
            return
        }

        lastNavigationWasServerError = true

        // error response, let's inspect if it's restoring a page or normal navigation
        if navigationResponse.response.url != initialURL {
            // just a normal loading error
            decisionHandler(.allow)
        } else {
            // first: clear that saved url, it's bad
            initialURL = nil

            // it's for the restored page, let's load the default url

            if let webviewURL = server.info.connection.webviewURL() {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: webviewURL))
            } else {
                // we don't have anything we can do about this
                decisionHandler(.allow)
            }
        }
    }

    // WKUIDelegate
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let style: UIAlertController.Style = {
            switch webView.traitCollection.userInterfaceIdiom {
            case .carPlay, .phone, .tv:
                return .actionSheet
            case .mac:
                return .alert
            case .pad, .unspecified, .vision:
                // without a touch to tell us where, an action sheet in the middle of the screen isn't great
                return .alert
            @unknown default:
                return .alert
            }
        }()

        let alertController = UIAlertController(title: nil, message: message, preferredStyle: style)

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Confirm.ok, style: .default, handler: { _ in
            completionHandler(true)
        }))

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Confirm.cancel, style: .cancel, handler: { _ in
            completionHandler(false)
        }))

        if presentedViewController != nil {
            Current.Log.error("attempted to present an alert when already presenting, bailing")
            completionHandler(false)
        } else {
            present(alertController, animated: true, completion: nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alertController = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)

        alertController.addTextField { textField in
            textField.text = defaultText
        }

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Prompt.ok, style: .default, handler: { _ in
            if let text = alertController.textFields?.first?.text {
                completionHandler(text)
            } else {
                completionHandler(defaultText)
            }
        }))

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Prompt.cancel, style: .cancel, handler: { _ in
            completionHandler(nil)
        }))

        if presentedViewController != nil {
            Current.Log.error("attempted to present an alert when already presenting, bailing")
            completionHandler(nil)
        } else {
            present(alertController, animated: true, completion: nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Alert.ok, style: .default, handler: { _ in
            completionHandler()
        }))

        alertController.popoverPresentationController?.sourceView = self.webView

        if presentedViewController != nil {
            Current.Log.error("attempted to present an alert when already presenting, bailing")
            completionHandler()
        } else {
            present(alertController, animated: true, completion: nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }
}

extension WebViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Prevent scrollView from scrolling past the top or bottom
        if scrollView.contentOffset.y > scrollView.contentSize.height - scrollView.bounds.height {
            scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height
        }
    }
}

extension WebViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
