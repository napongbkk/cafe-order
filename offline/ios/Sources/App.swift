import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  static var server: PosServer?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    application.isIdleTimerDisabled = true // the main machine stays awake for the other devices
    let w = UIWindow(frame: UIScreen.main.bounds)
    w.rootViewController = PosViewController()
    w.makeKeyAndVisible()
    window = w
    return true
  }

  func applicationWillTerminate(_ application: UIApplication) { AppDelegate.server?.stop() }
}

final class PosViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
  private var web: WKWebView?
  private let label = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.95, green: 0.97, blue: 0.98, alpha: 1)
    label.text = "Coconut POS กำลังเริ่มระบบ…"
    label.numberOfLines = 0; label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                 label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24)])
    startServer(port: 8080)
  }

  private func startServer(port: UInt16) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let data = docs.appendingPathComponent("CoconutPOS")
    guard let www = Bundle.main.resourceURL?.appendingPathComponent("www") else { label.text = "ไม่พบไฟล์แอป"; return }
    do {
      let s = try PosServer(dataDir: data, wwwDir: www, port: port, deviceName: UIDevice.current.name)
      s.start { [weak self] err in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if let err = err {
            if port < 8090 { s.stop(); self.startServer(port: port + 1) } else { self.label.text = "เริ่มระบบไม่สำเร็จ: \(err.localizedDescription)" }
            return
          }
          AppDelegate.server = s
          self.showWeb(port: port)
        }
      }
    } catch { label.text = "เริ่มระบบไม่สำเร็จ: \(error.localizedDescription)" }
  }

  private func showWeb(port: UInt16) {
    let cfg = WKWebViewConfiguration()
    let ucc = WKUserContentController()
    let js = "window.COCONUT_HOST={platform:'ios',print:function(h){try{window.webkit.messageHandlers.print.postMessage(String(h));return true}catch(e){return false}}};"
    ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    ucc.add(self, name: "print")
    cfg.userContentController = ucc
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []
    let w = WKWebView(frame: view.bounds, configuration: cfg)
    w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    w.navigationDelegate = self
    w.uiDelegate = self
    if #available(iOS 16.4, *) { w.isInspectable = true }
    view.addSubview(w)
    web = w
    label.isHidden = true
    w.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
  }

  // Links to other sites open in Safari.
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let u = action.request.url, let host = u.host, host != "127.0.0.1", u.scheme == "http" || u.scheme == "https" {
      UIApplication.shared.open(u); decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let u = action.request.url { UIApplication.shared.open(u) }
    return nil
  }
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    a.addAction(UIAlertAction(title: "ตกลง", style: .default) { _ in completionHandler() })
    present(a, animated: true)
  }
  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    a.addAction(UIAlertAction(title: "ยกเลิก", style: .cancel) { _ in completionHandler(false) })
    a.addAction(UIAlertAction(title: "ตกลง", style: .default) { _ in completionHandler(true) })
    present(a, animated: true)
  }
  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
    let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
    a.addTextField { $0.text = defaultText }
    a.addAction(UIAlertAction(title: "ยกเลิก", style: .cancel) { _ in completionHandler(nil) })
    a.addAction(UIAlertAction(title: "ตกลง", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
    present(a, animated: true)
  }

  // Receipts: the page hands over its HTML; iOS AirPrint shows its printer picker.
  private var printWeb: WKWebView?
  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "print", let html = message.body as? String, let port = AppDelegate.server?.port else { return }
    let pw = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    printWeb = pw
    pw.navigationDelegate = PrintDelegate.shared
    PrintDelegate.shared.onDone = { [weak self] w in
      let pc = UIPrintInteractionController.shared
      let info = UIPrintInfo(dictionary: nil); info.outputType = .general; info.jobName = "Coconut POS"
      pc.printInfo = info
      pc.printFormatter = w.viewPrintFormatter()
      if let v = self?.view { pc.present(from: CGRect(x: v.bounds.midX, y: 60, width: 1, height: 1), in: v, animated: true, completionHandler: nil) }
    }
    pw.loadHTMLString(html.replacingOccurrences(of: "window.print()", with: "void 0"), baseURL: URL(string: "http://127.0.0.1:\(port)/"))
  }
}

final class PrintDelegate: NSObject, WKNavigationDelegate {
  static let shared = PrintDelegate()
  var onDone: ((WKWebView) -> Void)?
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.onDone?(webView) }
  }
}
