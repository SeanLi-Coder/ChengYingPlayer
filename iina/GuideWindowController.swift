//
//  GuideWindowController.swift
//  iina
//
//  Created by Collider LI on 26/8/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Cocoa
@preconcurrency import WebKit

class GuideWindowController: NSWindowController {
  override var windowNibName: NSNib.Name {
    return NSNib.Name("GuideWindowController")
  }

  enum Page {
    case highlights
  }

  private var page = 0

  var highlightsWebView: WKWebView?
  @IBOutlet weak var highlightsContainerView: NSView!
  @IBOutlet weak var highlightsLoadingIndicator: NSProgressIndicator!
  @IBOutlet weak var highlightsLoadingFailedBox: NSBox!

  override func windowDidLoad() {
    super.windowDidLoad()
  }

  func show(pages: [Page]) {
    loadHighlightsPage()
    showWindow(self)
  }

  private func loadHighlightsPage() {
    window?.title = NSLocalizedString("guide.welcome.title", comment: "Welcome")
    let webView = WKWebView()
    highlightsWebView = webView
    webView.isHidden = true
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.navigationDelegate = self
    highlightsContainerView.addSubview(webView, positioned: .below, relativeTo: nil)
    Utility.quickConstraints(["H:|-0-[v]-0-|", "V:|-0-[v]-0-|"], ["v": webView])

    let title = NSLocalizedString("guide.welcome.title", comment: "Welcome")
    let subtitle = NSLocalizedString("guide.welcome.subtitle", comment: "Player description")
    let playback = NSLocalizedString("guide.welcome.playback", comment: "Playback feature")
    let clip = NSLocalizedString("guide.welcome.clip", comment: "Clip feature")
    let frames = NSLocalizedString("guide.welcome.frames", comment: "Frame extraction feature")
    let rotate = NSLocalizedString("guide.welcome.rotate", comment: "Rotation feature")
    let source = NSLocalizedString("guide.welcome.source", comment: "Source link")
    let html = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
          body { font: -apple-system-body; margin: 34px; color: -apple-system-label; }
          h1 { font: -apple-system-title1; margin: 0 0 8px; }
          p { color: -apple-system-secondary-label; line-height: 1.45; }
          ul { padding-left: 22px; line-height: 1.65; }
          a { color: -apple-system-link; }
        </style>
      </head>
      <body>
        <h1>\(title)</h1>
        <p>\(subtitle)</p>
        <ul>
          <li>\(playback)</li>
          <li>\(clip)</li>
          <li>\(frames)</li>
          <li>\(rotate)</li>
        </ul>
        <p><a href="https://github.com/SeanLi-Coder/ChengYingPlayer">\(source)</a></p>
      </body>
    </html>
    """
    webView.loadHTMLString(html, baseURL: nil)
    highlightsLoadingIndicator.startAnimation(nil)
  }

  @IBAction func continueBtnAction(_ sender: Any) {
    window?.close()
  }

  @IBAction func visitIINAWebsite(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.websiteLink)!)
  }
}

extension GuideWindowController: WKNavigationDelegate {
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url {
      if url.scheme == "about" {
        decisionHandler(.allow)
        return
      } else {
        NSWorkspace.shared.open(url)
      }
    }
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    highlightsLoadingIndicator.stopAnimation(nil)
    highlightsLoadingIndicator.isHidden = true
    highlightsLoadingFailedBox.isHidden = false
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    highlightsLoadingIndicator.stopAnimation(nil)
    highlightsLoadingIndicator.isHidden = true
    highlightsLoadingFailedBox.isHidden = false
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    highlightsLoadingIndicator.stopAnimation(nil)
    highlightsLoadingIndicator.isHidden = true
    highlightsWebView?.isHidden = false
  }
}

class GuideWindowButtonCell: NSButtonCell {
  override func awakeFromNib() {
    self.attributedTitle = NSAttributedString(
      string: title,
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.white]
    )
  }

  override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
    NSGraphicsContext.saveGraphicsState()
    let rectPath = NSBezierPath(
      roundedRect: NSRect(x: 2, y: 2, width: frame.width - 4, height: frame.height - 4),
      xRadius: 4, yRadius: 4
    )

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: 0)
    shadow.shadowBlurRadius = 1
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.set()

    if isHighlighted {
      NSColor.systemBlue.highlight(withLevel: 0.1)?.setFill()
    } else {
      NSColor.systemBlue.setFill()
    }
    rectPath.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}
