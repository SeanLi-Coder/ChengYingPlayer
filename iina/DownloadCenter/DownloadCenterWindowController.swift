import Cocoa
@preconcurrency import WebKit

final class DownloadCenterWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
  private let service: DownloadCenterService
  private(set) var webView: WKWebView!
  private let statusLabel = NSTextField(labelWithString: "")
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let spinner = NSProgressIndicator()
  private let reloadButton = NSButton()
  private let directoryButton = NSButton()
  private var placeholder: NSView!
  private var observer: NSObjectProtocol?
  private var loadedSession: DownloadCenterSession?
  private var loadGeneration = UUID()
  private var interactionGeneration = UUID()
  private var panel: NSOpenPanel?
  private var confirmations: [UUID: (Bool) -> Void] = [:]

  init(service: DownloadCenterService = .shared) {
    self.service = service
    super.init(window: nil)
    // init(window:) does not perform nib-style lazy loading for a nil window.
    loadWindow()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "downloadCenter")
  }

  override func loadWindow() {
    guard webView == nil else { return }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = downloadCenterString("title")
    window.contentMinSize = NSSize(width: 800, height: 600)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("ChengYingDownloadCenter")
    window.delegate = self
    self.window = window

    let content = DownloadCenterSurface()
    window.contentView = content
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController.add(DownloadCenterMessageProxy(owner: self), name: "downloadCenter")
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.setAccessibilityLabel(downloadCenterString("web.accessibility"))
    content.addSubview(webView)

    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    reloadButton.title = downloadCenterString("reload")
    reloadButton.image = ChengYingStyle.symbol("arrow.clockwise")
    reloadButton.imagePosition = .imageLeading
    reloadButton.target = self
    reloadButton.action = #selector(reloadPage)
    directoryButton.title = downloadCenterString("directory")
    directoryButton.image = ChengYingStyle.symbol("folder")
    directoryButton.imagePosition = .imageLeading
    directoryButton.target = self
    directoryButton.action = #selector(chooseDirectory)
    [reloadButton, directoryButton].forEach(ChengYingStyle.secondaryButton)
    let toolbar = NSStackView(views: [statusLabel, directoryButton, reloadButton])
    toolbar.orientation = .horizontal
    toolbar.alignment = .centerY
    toolbar.spacing = 12
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(toolbar)

    spinner.style = .spinning
    spinner.controlSize = .regular
    spinner.isDisplayedWhenStopped = false
    messageLabel.font = .systemFont(ofSize: 14)
    messageLabel.alignment = .center
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.maximumNumberOfLines = 0
    let loading = NSStackView(views: [spinner, messageLabel])
    loading.orientation = .vertical
    loading.spacing = 16
    loading.alignment = .centerX
    loading.translatesAutoresizingMaskIntoConstraints = false
    placeholder = DownloadCenterSurface()
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    placeholder.addSubview(loading)
    content.addSubview(placeholder)
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
      toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      toolbar.heightAnchor.constraint(equalToConstant: 34),
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
      webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      placeholder.topAnchor.constraint(equalTo: webView.topAnchor),
      placeholder.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
      placeholder.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
      placeholder.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
      loading.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
      loading.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
      loading.widthAnchor.constraint(lessThanOrEqualTo: placeholder.widthAnchor, constant: -80),
      messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 550),
    ])
    observer = NotificationCenter.default.addObserver(forName: .downloadCenterStateChanged, object: service, queue: .main) { [weak self] _ in
      self?.renderState()
    }
    window.center()
    renderState()
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    service.start()
    renderState()
  }

  private func renderState() {
    guard isWindowLoaded else { return }
    directoryButton.isEnabled = false
    switch service.state {
    case .idle, .starting:
      statusLabel.stringValue = downloadCenterString("status.starting")
      messageLabel.stringValue = downloadCenterString("status.starting.detail")
      placeholder.isHidden = false
      spinner.startAnimation(nil)
      reloadButton.isEnabled = false
    case .failed(let error):
      loadedSession = nil
      loadGeneration = UUID()
      webView.stopLoading()
      spinner.stopAnimation(nil)
      statusLabel.stringValue = downloadCenterString("status.failed")
      messageLabel.stringValue = error.localizedDescription
      placeholder.isHidden = false
      reloadButton.isEnabled = true
    case .ready(let session):
      statusLabel.stringValue = downloadCenterString("status.ready")
      reloadButton.isEnabled = true
      directoryButton.isEnabled = loadedSession == session && placeholder.isHidden
      guard loadedSession != session else { return }
      load(session)
    }
  }

  private func load(_ session: DownloadCenterSession) {
    loadedSession = session
    loadGeneration = UUID()
    let identifier = loadGeneration
    placeholder.isHidden = false
    spinner.startAnimation(nil)
    messageLabel.stringValue = downloadCenterString("status.loading")
    guard let cookie = session.cookie else { showFailure(DownloadCenterError.protocolViolation); return }
    webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.loadGeneration == identifier,
              case .ready(let current) = self.service.state, current == session else { return }
        self.webView.load(URLRequest(url: session.url, cachePolicy: .reloadIgnoringLocalCacheData))
      }
    }
  }

  @objc private func reloadPage() {
    switch service.state {
    case .ready(let session): load(session)
    case .idle, .failed: service.start()
    case .starting: break
    }
  }

  @objc private func chooseDirectory() {
    guard panel == nil, let window, window.isVisible, window.attachedSheet == nil, trustedSession != nil else { return }
    let chooser = NSOpenPanel()
    chooser.canChooseDirectories = true
    chooser.canChooseFiles = false
    chooser.canCreateDirectories = true
    chooser.allowsMultipleSelection = false
    chooser.prompt = downloadCenterString("directory.choose")
    chooser.message = downloadCenterString("directory.message")
    panel = chooser
    let identifier = loadGeneration
    let interaction = interactionGeneration
    chooser.beginSheetModal(for: window) { [weak self, weak chooser] response in
      guard let self else { return }
      self.panel = nil
      guard response == .OK, let url = chooser?.url, url.isFileURL,
            self.loadGeneration == identifier, self.interactionGeneration == interaction, self.trustedSession != nil,
            let json = try? JSONSerialization.data(withJSONObject: [url.path]),
            let values = String(data: json, encoding: .utf8) else { return }
      // Serialize, never interpolate a path as executable JavaScript.
      let script = "window.chengyingDownloadCenter && window.chengyingDownloadCenter.setDirectory(\(values)[0]);"
      self.webView.evaluateJavaScript(script) { [weak self] _, error in
        if error != nil { self?.showFailure(DownloadCenterError.request, replacePage: false) }
      }
    }
  }

  private var trustedSession: DownloadCenterSession? {
    guard case .ready(let session) = service.state, loadedSession == session,
          let url = webView?.url, session.contains(url), url.path == "/" else { return nil }
    return session
  }

  fileprivate func receive(_ message: WKScriptMessage) {
    guard message.name == "downloadCenter", message.webView === webView, let session = trustedSession,
          session.acceptsOrigin(scheme: message.frameInfo.securityOrigin.protocol,
                                host: message.frameInfo.securityOrigin.host,
                                port: message.frameInfo.securityOrigin.port,
                                isMainFrame: message.frameInfo.isMainFrame),
          let command = DownloadCenterCommand(message: message.body) else { return }
    switch command {
    case .chooseDirectory: chooseDirectory()
    case .output(let action, let jobID, let itemID, let index):
      let identifier = loadGeneration
      let interaction = interactionGeneration
      service.resolveOutput(jobID: jobID, itemID: itemID, index: index) { [weak self] result in
        guard let self, self.loadGeneration == identifier, self.interactionGeneration == interaction, self.trustedSession == session,
              self.window?.isVisible == true else { return }
        do {
          let output = try result.get()
          let url = try output.validatedURL(forPlayback: action == "play")
          if action == "play" { PlayerCore.activeOrNew.openURL(url) }
          else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch { self.showFailure(DownloadCenterError.unsafeOutput, replacePage: false) }
      }
    }
  }

  private func showFailure(_ error: Error, replacePage: Bool = true) {
    spinner.stopAnimation(nil)
    statusLabel.stringValue = error.localizedDescription
    if replacePage {
      messageLabel.stringValue = error.localizedDescription
      placeholder.isHidden = false
      directoryButton.isEnabled = false
    }
  }

  func windowWillClose(_ notification: Notification) {
    interactionGeneration = UUID()
    panel?.cancel(nil)
    panel = nil
    let callbacks = Array(confirmations.values)
    confirmations.removeAll()
    callbacks.forEach { $0(false) }
    if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel) }
    // The shared service, task storage, and downloads intentionally outlive this window.
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let session = loadedSession, let url = navigationAction.request.url,
          navigationAction.targetFrame?.isMainFrame == true, session.contains(url), url.path == "/" else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard trustedSession != nil else { return }
    placeholder.isHidden = true
    spinner.stopAnimation(nil)
    directoryButton.isEnabled = true
    statusLabel.stringValue = downloadCenterString("status.ready")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if (error as NSError).code != NSURLErrorCancelled { showFailure(DownloadCenterError.request) }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if (error as NSError).code != NSURLErrorCancelled { showFailure(DownloadCenterError.request) }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    showFailure(DownloadCenterError.request)
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    guard let session = trustedSession, let window, window.isVisible, window.attachedSheet == nil,
          session.acceptsOrigin(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host,
                                port: frame.securityOrigin.port, isMainFrame: frame.isMainFrame) else {
      completionHandler(false)
      return
    }
    let identifier = UUID()
    confirmations[identifier] = completionHandler
    let alert = NSAlert()
    alert.messageText = downloadCenterString("confirm.title")
    alert.informativeText = String(message.prefix(4096))
    alert.addButton(withTitle: downloadCenterString("confirm.continue"))
    alert.addButton(withTitle: downloadCenterString("confirm.cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      self?.confirmations.removeValue(forKey: identifier)?(response == .alertFirstButtonReturn)
    }
  }
}

private final class DownloadCenterMessageProxy: NSObject, WKScriptMessageHandler {
  weak var owner: DownloadCenterWindowController?
  init(owner: DownloadCenterWindowController) { self.owner = owner }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.receive(message)
  }
}

private final class DownloadCenterSurface: NSView {
  override func draw(_ dirtyRect: NSRect) { ChengYingStyle.surface.setFill(); dirtyRect.fill() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
