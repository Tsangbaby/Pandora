import UIKit

final class ProbeWindow: PDSystemWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let root = rootViewController as? ProbeController else { return nil }
        let local = root.view.convert(point, from: self)
        if root.state.phase == .idle && !root.panel.frame.contains(local) { return nil }
        return super.hitTest(point, with: event)
    }
}

final class ProbeController: UIViewController {
    private(set) var state = ProbeState()
    let panel = UIView()
    private let titleLabel = UILabel()
    private let status = UILabel()
    private let startButton = UIButton(type: .system)
    private let focusButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let card = UIView()
    private var session: PDSceneSession?
    private var keyboardHeight: CGFloat = 0

    override var shouldAutorotate: Bool { false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        panel.backgroundColor = .secondarySystemBackground
        panel.layer.cornerRadius = 12
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.separator.cgColor
        view.addSubview(panel)
        titleLabel.text = "Pandora · 单 Scene 实验"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        status.text = "先打开备忘录，再手动挂载；不会自动切换 App。"
        status.font = .systemFont(ofSize: 12)
        status.numberOfLines = 3
        panel.addSubview(titleLabel)
        panel.addSubview(status)
        setup(startButton, "挂载备忘录", #selector(start))
        setup(focusButton, "请求输入", #selector(focus))
        setup(stopButton, "结束实验", #selector(stop))
        setup(closeButton, "关闭", #selector(close))
        card.clipsToBounds = true
        card.layer.cornerRadius = 16
        card.backgroundColor = .systemBackground
        card.isHidden = true
        view.insertSubview(card, belowSubview: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        refreshButtons()
    }

    private func setup(_ button: UIButton, _ text: String, _ action: Selector) {
        button.setTitle(text, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
        panel.addSubview(button)
    }

    @objc private func start() {
        guard let token = state.begin() else { return }
        do {
            let candidate = try PDSceneSession.capture()
            guard state.attach(token) else { candidate.invalidate(); return }
            session = candidate
            if let host = candidate.hostedView { card.addSubview(host) }
            card.isHidden = false
            view.backgroundColor = .black
            status.text = "已添加宿主；请检查画面、滚动和落字。未判定通过。"
            view.setNeedsLayout()
        } catch {
            state.stop()
            status.text = error.localizedDescription
        }
        refreshButtons()
    }

    @objc private func focus() {
        guard state.phase == .attached, !state.focusRequested, let session = session else { return }
        do {
            try session.requestFocus()
            _ = state.markFocus(state.generation)
            status.text = "已发出焦点请求；点卡片正文输入，确认文字只落在备忘录。"
        } catch { end(error.localizedDescription) }
        refreshButtons()
    }

    @objc private func stop() { end("已移除实验宿主；请检查原生界面和输入是否正常。") }
    @objc private func close() { PDProbeRuntime.stopControls() }

    func end(_ message: String) {
        state.stop()
        session?.invalidate()
        session = nil
        card.isHidden = true
        keyboardHeight = 0
        view.backgroundColor = .clear
        status.text = message
        refreshButtons()
    }

    func foregroundChanged() {
        if let session = session, !session.remainsForeground {
            end("前台场景改变，实验已结束；不会自动重新挂载。")
        }
    }

    private func refreshButtons() {
        startButton.isEnabled = state.phase == .idle
        focusButton.isEnabled = state.phase == .attached && !state.focusRequested
        stopButton.isEnabled = state.phase != .idle
    }

    @objc private func keyboard(_ note: Notification) {
        guard state.phase == .attached else { return }
        if note.name == UIResponder.keyboardWillHideNotification {
            keyboardHeight = 0
        } else if let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            let frame = view.convert(value.cgRectValue, from: nil).intersection(view.bounds)
            keyboardHeight = !frame.isNull && frame.maxY >= view.bounds.maxY - 1 ? frame.height : 0
        }
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        panel.frame = CGRect(x: 12, y: max(54, view.safeAreaInsets.top) + 4,
                             width: max(0, width - 24), height: 132)
        titleLabel.frame = CGRect(x: 12, y: 8, width: panel.bounds.width - 76, height: 24)
        closeButton.frame = CGRect(x: panel.bounds.width - 56, y: 0, width: 52, height: 40)
        status.frame = CGRect(x: 12, y: 34, width: panel.bounds.width - 24, height: 48)
        let cellWidth = (panel.bounds.width - 16) / 3
        for (index, button) in [startButton, focusButton, stopButton].enumerated() {
            button.frame = CGRect(x: 8 + CGFloat(index) * cellWidth, y: 88, width: cellWidth, height: 40)
        }
        guard let session = session, let host = session.hostedView else { return }
        let top = panel.frame.maxY + 12
        let bottom = view.bounds.height - max(12, view.safeAreaInsets.bottom) - keyboardHeight
        let available = CGRect(x: 12, y: top, width: width - 24, height: max(0, bottom - top))
        guard let frame = ProbeGeometry.fit(source: session.sourceSize, available: available) else {
            end("可用空间不足，已安全结束；请收起键盘后重试。")
            return
        }
        UIView.performWithoutAnimation {
            card.frame = frame
            host.bounds = CGRect(origin: .zero, size: session.sourceSize)
            host.transform = CGAffineTransform(scaleX: frame.width / session.sourceSize.width,
                                               y: frame.height / session.sourceSize.height)
            host.center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

@objc(PDProbeRuntime)
final class PDProbeRuntime: NSObject {
    private static let shared = PDProbeRuntime()
    private var root: ProbeController?
    private var lease: PDOverlayLease?
    private var armedUntil: TimeInterval = 0

    @objc static func showControls() {
        precondition(Thread.isMainThread)
        guard shared.root == nil else { return }
        shared.armedUntil = ProcessInfo.processInfo.systemUptime + 30
        foregroundChanged()
    }

    private func presentControls() {
        armedUntil = 0 // Consume before calling UIKit, including on an ABI refusal.
        let root = ProbeController()
        let window = ProbeWindow(frame: UIScreen.main.fixedCoordinateSpace.bounds)
        window.rootViewController = root
        do {
            let lease = try PDOverlayLease.attach(window: window, onOrientationChange: {
                PDProbeRuntime.stopControls()
            })
            guard PDProbeCanPresent() else { lease.invalidate(); return }
            self.root = root
            self.lease = lease
        } catch {
            window.isHidden = true
            window.rootViewController = nil
            NSLog("[Pandora] Controls refused: %@", error.localizedDescription)
        }
    }

    @objc static func stopControls() {
        precondition(Thread.isMainThread)
        let runtime = shared
        let root = runtime.root
        let lease = runtime.lease
        runtime.armedUntil = 0
        runtime.root = nil
        runtime.lease = nil
        root?.end("实验已关闭。")
        lease?.invalidate()
    }

    @objc static func foregroundChanged() {
        precondition(Thread.isMainThread)
        let runtime = shared
        if let root = runtime.root {
            if PDProbeCanPresent() { root.foregroundChanged() }
            else { stopControls() }
        } else if runtime.armedUntil > ProcessInfo.processInfo.systemUptime && PDProbeCanPresent() {
            runtime.presentControls()
        }
    }
}
