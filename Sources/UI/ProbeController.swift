import UIKit

final class ProbeRootView: UIView {
    weak var owner: ProbeController?
    private weak var expectedWindow: UIWindow?
    private weak var expectedSuperview: UIView?
    private var hasParent = false
    private var hasAttached = false
    private(set) var identityLost = false
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let root = owner else { return nil }
        if (identityLost || (root.state.phase != .attached && root.state.phase != .mounting)) && !root.panel.frame.contains(point) { return nil }
        return super.hitTest(point, with: event)
    }
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if !hasParent {
            if let superview = superview { expectedSuperview = superview; hasParent = true }
            return
        }
        if superview !== expectedSuperview {
            identityLost = true
            if let root = owner { PDProbeRuntime.rootDetached(root) }
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if !hasAttached {
            if let window = window { expectedWindow = window; hasAttached = true }
            return
        }
        if window !== expectedWindow {
            identityLost = true
            if let root = owner { PDProbeRuntime.rootDetached(root) }
        }
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
    private var updatingSessionLayout = false

    override func loadView() {
        let root = ProbeRootView()
        root.owner = self
        view = root
    }

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
        card.backgroundColor = .clear
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
        defer { PDProbeRuntime.resumeAfterNativeOperation(self) }
        guard PDProbeRuntime.permitsInteraction(self), (view as? ProbeRootView)?.identityLost == false, let token = state.begin() else { return }
        refreshButtons()
        do {
            layoutControls()
            card.frame = view.bounds
            card.isHidden = false
            let candidate = try PDSceneSession.capture(in: card, onOwnershipChange: { [weak self] in
                guard let root = self else { return }
                if PDProbeRuntime.isClosing(root) { PDProbeRuntime.stopControls(); return }
                guard root.state.generation == token else { return }
                _ = root.end("系统呈现关系变化，实验已让出；不会自动再次接管。")
            })
            session = candidate // Keep cleanup handle before layout/activation.
            try layoutSession(candidate)
            try candidate.activate()
            guard state.attach(token) else {
                _ = end("准备已取消，未提交界面状态。")
                return
            }
            card.isHidden = false
            view.backgroundColor = .black
            status.text = "原生呈现者已承载完整内容层；请先测试触摸，再请求输入。尚未验收。"
        } catch {
            _ = end(error.localizedDescription)
        }
        refreshButtons()
    }

    @objc private func focus() {
        defer { PDProbeRuntime.resumeAfterNativeOperation(self) }
        guard PDProbeRuntime.permitsInteraction(self), (view as? ProbeRootView)?.identityLost == false,
              state.phase == .attached, !state.focusRequested, let session = session else { return }
        do {
            try session.requestFocus()
            _ = state.markFocus(state.generation)
            status.text = "已发出焦点请求；点卡片正文输入，确认文字只落在备忘录。"
        } catch { end(error.localizedDescription) }
        refreshButtons()
    }

    @objc private func stop() { end("已移除实验宿主；请检查原生界面和输入是否正常。") }
    @objc private func close() { PDProbeRuntime.stopControls() }

    @discardableResult
    func end(_ message: String) -> Bool {
        guard let token = state.beginCancellation() else { return false }
        var succeeded = false
        do {
            try session?.finish()
            try PDSceneSession.cancelPending()
            session = nil
            succeeded = true
            status.text = message
        } catch {
            status.text = "清理未确认，已禁止再次挂载：\(error.localizedDescription)"
        }
        _ = state.finishCancellation(token, succeeded: succeeded)
        card.isHidden = true
        keyboardHeight = 0
        view.backgroundColor = .clear
        refreshButtons()
        return succeeded
    }

    func foregroundChanged() {
        if let session = session, !session.remainsForeground {
            end("前台场景改变，实验已结束；不会自动重新挂载。")
        }
    }

    func refreshEnvironment() { refreshButtons() }

    func blockOverlayCleanup(_ message: String) {
        if let token = state.beginCancellation() { _ = state.finishCancellation(token, succeeded: false) }
        status.text = message
        refreshButtons()
    }

    private func refreshButtons() {
        let permitted = PDProbeRuntime.permitsInteraction(self)
        startButton.isEnabled = permitted && state.phase == .idle
        focusButton.isEnabled = permitted && state.phase == .attached && !state.focusRequested
        stopButton.isEnabled = state.phase != .idle
    }

    @objc private func keyboard(_ note: Notification) {
        guard state.phase == .attached else { return }
        if note.name == UIResponder.keyboardWillHideNotification {
            keyboardHeight = 0
        } else if let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
                  let window = view.window {
            let frame = view.convert(value.cgRectValue, from: window.screen.coordinateSpace).intersection(view.bounds)
            keyboardHeight = !frame.isNull && frame.maxY >= view.bounds.maxY - 1 ? frame.height : 0
        }
        view.setNeedsLayout()
    }

    private func layoutControls() {
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
    }

    private func layoutSession(_ session: PDSceneSession) throws {
        guard !updatingSessionLayout else { return }
        updatingSessionLayout = true
        defer { updatingSessionLayout = false }
        card.frame = view.bounds // One shared coordinate plane; no raw-host scaling.
        let top = panel.frame.maxY + 12
        let bottom = view.bounds.height - max(12, view.safeAreaInsets.bottom) - keyboardHeight
        let available = CGRect(x: 12, y: top, width: view.bounds.width - 24, height: max(0, bottom - top))
        guard let frame = ProbeGeometry.fit(source: session.sourceSize, available: available) else {
            throw NSError(domain: "com.tsangbaby.pandora.geometry", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "可用空间不足，需结束实验；不会缩到无法输入。"])
        }
        try session.update(frame: frame)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutControls()
        guard let session = session else { return }
        do { try layoutSession(session) }
        catch { end(error.localizedDescription) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

@objc(PDProbeRuntime)
final class PDProbeRuntime: NSObject {
    private static let shared = PDProbeRuntime()
    private var root: ProbeController?
    private var lease: PDOverlayLease?
    private var armedUntil: TimeInterval = 0
    private var closingRequested = false

    @objc static func showControls() {
        precondition(Thread.isMainThread)
        guard shared.root == nil else { return }
        shared.armedUntil = ProcessInfo.processInfo.systemUptime + 30
        foregroundChanged()
    }

    private func presentControls() {
        armedUntil = 0
        let root = ProbeController()
        do {
            try PDOverlayLease.finishPending()
            let lease = try PDOverlayLease.attach(controller: root, onInvalidation: {
                PDProbeRuntime.stopControls()
            })
            guard PDProbeCanPresent() else { try lease.finish(); return }
            self.root = root
            self.lease = lease
            root.refreshEnvironment()
        } catch {
            NSLog("[Pandora] Native controls refused: %@", error.localizedDescription)
        }
    }

    @objc static func stopControls() {
        precondition(Thread.isMainThread)
        let runtime = shared
        let root = runtime.root
        let lease = runtime.lease
        runtime.armedUntil = 0
        runtime.closingRequested = true
        guard root?.end("实验已结束；请检查原生画面、滚动和输入是否恢复。") ?? true else { return }
        do {
            try lease?.finish()
            try PDOverlayLease.finishPending()
            runtime.root = nil
            runtime.lease = nil
            runtime.closingRequested = false
        } catch {
            root?.blockOverlayCleanup("控制层清理未确认：\(error.localizedDescription)")
        }
    }

    static func permitsInteraction(_ root: ProbeController) -> Bool {
        return ProbeAdmission.permits(published: shared.root === root, closing: shared.closingRequested,
                                      overlayValid: shared.lease?.valid == true)
    }

    static func isClosing(_ root: ProbeController) -> Bool {
        return shared.root === root && shared.closingRequested
    }

    static func resumeAfterNativeOperation(_ root: ProbeController) {
        // Only a real operation unwind may resume an in-flight close. A failed
        // overlay finish has valid=false and settles blocked, without a retry loop.
        guard ProbeAdmission.resumesClose(published: shared.root === root, closing: shared.closingRequested,
                                          overlayValid: shared.lease?.valid == true) else { return }
        DispatchQueue.main.async { [weak root] in
            guard let root = root, isClosing(root), shared.lease?.valid == true else { return }
            stopControls()
        }
    }

    static func rootDetached(_ root: ProbeController) {
        DispatchQueue.main.async { [weak root] in
            guard let root = root, shared.root === root else { return }
            stopControls()
        }
    }

    @objc static func foregroundChanged() {
        precondition(Thread.isMainThread)
        let runtime = shared
        if let root = runtime.root {
            if PDProbeCanPresent() && runtime.lease?.valid == true { root.foregroundChanged() }
            else { stopControls() }
        } else if runtime.armedUntil > ProcessInfo.processInfo.systemUptime && PDProbeCanPresent() {
            runtime.presentControls()
        }
    }
}
