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
        if root.panel.isHidden {
            return identityLost ? nil : root.dockedSubview(at: point, event: event)
        }
        if (identityLost || (root.state.phase != .attached && root.state.phase != .mounting)) && !root.panel.frame.contains(point) { return nil }
        if root.blocksRevealInput && !root.panel.frame.contains(point) { return self }
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

private extension WorkspaceRotation.Member {
    var appName: String { self == .notes ? "备忘录" : "文件" }
    var probeTarget: PDProbeTarget { self == .notes ? .notes : .files }
}

private extension PDProbeTarget {
    var rotationMember: WorkspaceRotation.Member { self == .files ? .files : .notes }
}

final class ProbeController: UIViewController {
    let target: PDProbeTarget
    private(set) var rotationOffer: WorkspaceRotation.Ticket?
    private(set) var dockTicket: WorkspaceDock.Ticket?
    private var edgeConfirmation: (direction: WorkspaceEdgeMotion.Direction, uptime: TimeInterval)?
    private let activeEdge = ProbeGestureEdge(dockTab: false)
    private let dockEdge = ProbeGestureEdge(dockTab: true)
    private var cardMotion: ProbeCardMotion?
    fileprivate var dockHitFrame: CGRect? { dockEdge.isHidden ? nil : dockEdge.frame }
    fileprivate var blocksRevealInput: Bool { cardMotion?.blocksContent == true }
    fileprivate var member: WorkspaceRotation.Member { target.rotationMember }
    private var isFiles: Bool { target == .files }
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
    private var keyboardEnvironment = ProbeKeyboardEnvironment()
    private var keyboardObservers: [NSObjectProtocol] = []
    private weak var laidOutSession: PDSceneSession?
    private var appliedContentFrame: CGRect?
    private var updatingSessionLayout = false
    private var requestingFocus = false

    init(target: PDProbeTarget, rotationOffer: WorkspaceRotation.Ticket? = nil) {
        self.target = target
        self.rotationOffer = rotationOffer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

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
        titleLabel.text = isFiles ? "文件工作卡" : "备忘录工作卡"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        if let offer = rotationOffer {
            status.text = "已交还\(offer.source.appName)。确认页面后，从短横线上滑或点挂载\(member.appName)。"
        } else {
            status.text = isFiles ? "手动挂载当前「文件」场景；只测画面、滚动、点击及归还。" :
                "先打开备忘录，再手动挂载；不会自动切换 App。"
        }
        status.font = .systemFont(ofSize: 12)
        status.numberOfLines = 3
        panel.addSubview(titleLabel)
        panel.addSubview(status)
        setup(startButton, isFiles ? "挂载文件" : "挂载备忘录", #selector(start))
        setup(focusButton, "请求输入", #selector(focus))
        focusButton.isHidden = isFiles
        setup(stopButton, "结束实验", #selector(stop))
        setup(closeButton, "关闭", #selector(close))
        card.backgroundColor = .clear
        card.isHidden = true
        view.insertSubview(card, belowSubview: panel)
        cardMotion = ProbeCardMotion(root: view, carrier: card, panel: panel)
        configureEdges()
        // Observe the environment during idle/mounting too, but never apply
        // layout to an uncommitted session. Missing past events remain unknown.
        let names: [Notification.Name] = [UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification]
        keyboardObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.keyboard(note)
            }
        }
        panel.accessibilityValue = keyboardEnvironment.accessibilitySummary
        refreshButtons()
    }

    private func setup(_ button: UIButton, _ text: String, _ action: Selector) {
        button.setTitle(text, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
        panel.addSubview(button)
    }

    private func configureEdges() {
        activeEdge.accessibilityLabel = "工作组卡边"
        activeEdge.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "向上：轮换或挂载", actionHandler: { [weak self] _ in self?.handleSwipe(.up) == true }),
            UIAccessibilityCustomAction(name: "向下：收起工作卡", actionHandler: { [weak self] _ in self?.handleSwipe(.down) == true })
        ]
        panel.addSubview(activeEdge)
        activeEdge.isHidden = true
        activeEdge.permitsGesture = { [weak self] in self?.canSwipeHeader == true }
        activeEdge.onSwipe = { [weak self] direction in self?.handleSwipe(direction) == true }
        // The dock lives on the same verified root, never in its own window.
        dockEdge.accessibilityLabel = "展开\(member.appName)工作卡"
        dockEdge.accessibilityHint = "向上滑动，或双击激活"
        dockEdge.isHidden = true
        view.addSubview(dockEdge)
        dockEdge.permitsGesture = { [weak self] in
            guard let self, let ticket = self.dockTicket else { return false }
            return PDProbeRuntime.canRestoreDock(self, ticket: ticket)
        }
        dockEdge.onSwipe = { [weak self] direction in
            guard direction == .up, let self, let ticket = self.dockTicket else { return false }
            return PDProbeRuntime.restoreDock(from: self, ticket: ticket)
        }
    }

    @objc private func start() {
        defer { PDProbeRuntime.resumeAfterNativeOperation(self) }
        guard let overlay = PDProbeRuntime.interactiveOverlay(for: self),
              (view as? ProbeRootView)?.identityLost == false, let token = state.begin() else { return }
        refreshButtons()
        do {
            layoutControls()
            card.frame = view.bounds
            card.isUserInteractionEnabled = false
            card.isHidden = false
            let candidate = try PDSceneSession.capture(in: card, from: overlay, onOwnershipChange: { [weak self] in
                guard let root = self else { return }
                if PDProbeRuntime.isClosing(root) { PDProbeRuntime.stopControls(); return }
                guard root.state.generation == token else { return }
                _ = root.end("系统呈现关系变化，实验已让出；不会自动再次接管。")
            })
            session = candidate // Keep cleanup handle before layout/activation.
            try layoutSession(candidate)
            guard state.generation == token, state.phase == .mounting,
                  PDProbeRuntime.interactiveOverlay(for: self) === overlay,
                  let frame = appliedContentFrame, let cardMotion else {
                _ = end("挂载已取消，没有激活新的卡片。")
                return
            }
            cardMotion.prepare(frame: view.convert(frame, from: card), generation: token,
                               reduceMotion: UIAccessibility.isReduceMotionEnabled)
            guard cardMotion.blocksContent else {
                _ = end("入场几何未准备好，没有激活新的卡片。")
                return
            }
            try candidate.activate()
            guard state.attach(token) else {
                _ = end("准备已取消，未提交界面状态。")
                return
            }
            // Reconcile live outside-keyboard evidence after the native owner
            // has transferred ALL hosted layers, never before acquisition.
            try layoutSession(candidate)
            guard PDProbeRuntime.recordMount(for: self, generation: token) else {
                _ = end("挂载资格已取消，已撤销本次接入。")
                return
            }
            rotationOffer = nil
            clearDock()
            card.isHidden = false
            status.text = "从上方短横线上滑交还，再打开\(member.partner.appName)；下滑收起。"
            cardMotion.reveal(generation: token) { [weak self] in
                guard let self, self.state.generation == token, self.state.phase == .attached,
                      (self.viewIfLoaded as? ProbeRootView)?.identityLost == false,
                      PDProbeRuntime.permitsInteraction(self) else { return }
                self.card.isUserInteractionEnabled = true
                self.refreshButtons()
            }
        } catch {
            _ = end(error.localizedDescription)
        }
        refreshButtons()
    }

    @objc private func focus() {
        defer { PDProbeRuntime.resumeAfterNativeOperation(self) }
        guard !isFiles, !blocksRevealInput, !requestingFocus, PDProbeRuntime.permitsInteraction(self),
              (view as? ProbeRootView)?.identityLost == false,
              state.phase == .attached, !state.focusRequested, let session = session else { return }
        let token = state.generation
        requestingFocus = true
        edgeConfirmation = nil
        defer { requestingFocus = false }
        do {
            try layoutSession(session) // Fresh positive occlusion check before requesting input.
            guard self.session === session, state.generation == token, PDProbeRuntime.permitsInteraction(self) else { return }
            try session.requestFocus()
            guard self.session === session, state.markFocus(token) else { return }
            status.text = "已发出焦点请求；点卡片正文输入，确认文字只落在备忘录。"
        } catch { end(error.localizedDescription) }
        refreshButtons()
    }

    fileprivate var canUseHeader: Bool {
        state.phase == .attached && !updatingSessionLayout && !requestingFocus && !blocksRevealInput &&
            (viewIfLoaded as? ProbeRootView)?.identityLost == false && session?.remainsForeground == true
    }

    private var canSwipeHeader: Bool {
        guard (viewIfLoaded as? ProbeRootView)?.identityLost == false,
              PDProbeRuntime.permitsInteraction(self) else { return false }
        return canUseHeader || (state.phase == .idle && rotationOffer != nil && PDProbeRuntime.canMount(self))
    }

    fileprivate var edgeKeyboard: WorkspaceEdgeMotion.Keyboard {
        switch keyboardEnvironment.observation {
        case .hidden: return .hidden
        case .unknown: return .unknown
        case .frame(let frame):
            guard let window = viewIfLoaded?.window else { return .unknown }
            let overlap = frame.intersection(window.screen.coordinateSpace.bounds)
            return !overlap.isNull && overlap.width > 1 && overlap.height > 1 ? .visible : .unknown
        }
    }

    private func handleSwipe(_ direction: WorkspaceEdgeMotion.Direction) -> Bool {
        guard canSwipeHeader else { return false }
        if state.phase == .idle {
            guard direction == .up, rotationOffer != nil else { return false }
            start()
            return state.phase == .attached
        }
        let now = ProcessInfo.processInfo.systemUptime
        let repeated = edgeConfirmation.map { $0.direction == direction &&
            WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: $0.uptime, now: now) } ?? false
        let action = direction == .up ? "轮换到\(member.partner.appName)" : "收起工作卡"
        switch WorkspaceEdgeMotion.decision(keyboard: edgeKeyboard, repeated: repeated) {
        case .finishEditing:
            edgeConfirmation = nil
            status.text = "请先完成编辑并收起键盘，再\(action)。"
            return false
        case .confirm:
            edgeConfirmation = (direction, now)
            status.text = "若键盘已收起，请在 6 秒内同向再滑一次，确认\(action)。"
            return true
        case .apply:
            edgeConfirmation = nil
            if direction == .down { return PDProbeRuntime.dock(from: self) }
            return PDProbeRuntime.rotate(from: self)
        }
    }

    @objc private func stop() { end("已移除实验宿主；请检查原生界面和输入是否正常。") }
    @objc private func close() { PDProbeRuntime.stopControls() }

    @discardableResult
    func end(_ message: String) -> Bool {
        guard let token = state.beginCancellation() else { return false }
        edgeConfirmation = nil
        PDProbeRuntime.discardMountOffer(for: self)
        // Cancel local visual/input state before letting native teardown reenter.
        activeEdge.isHidden = true
        activeEdge.resetPose()
        clearDock()
        card.isUserInteractionEnabled = false
        cardMotion?.clear()
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
        appliedContentFrame = nil
        laidOutSession = nil
        refreshButtons()
        return succeeded
    }

    fileprivate var dockCandidateFrame: CGRect? {
        guard let root = viewIfLoaded as? ProbeRootView, root.window != nil, !root.identityLost else { return nil }
        return WorkspaceEdgeMotion.dockFrame(in: root.bounds, bottomInset: root.safeAreaInsets.bottom)
    }

    fileprivate var isReleasedForDock: Bool { state.phase == .idle && session == nil }

    fileprivate func dockedSubview(at point: CGPoint, event: UIEvent?) -> UIView? {
        guard let ticket = dockTicket, isReleasedForDock, edgeKeyboard != .visible,
              let frame = dockHitFrame, frame == dockCandidateFrame, frame.contains(point),
              let root = viewIfLoaded, PDProbeRuntime.hasParkedDock(self, ticket: ticket) else { return nil }
        // Fast touch routing uses local identities; the gesture validates the
        // native lease on entry and the return structure again before mounting.
        return dockEdge.hitTest(dockEdge.convert(point, from: root), with: event)
    }

    fileprivate func showDock(_ ticket: WorkspaceDock.Ticket) {
        dockTicket = ticket
        panel.isHidden = true
        layoutDock()
    }

    fileprivate func restoreFromDock() -> Bool {
        dockEdge.isHidden = true
        dockEdge.resetPose()
        panel.isHidden = false
        status.text = "正在重新核对当前 App；不会自动恢复键盘。"
        start()
        return state.phase == .attached && dockTicket == nil
    }

    fileprivate func clearDock() {
        dockTicket = nil
        dockEdge.isHidden = true
        dockEdge.resetPose()
    }

    private func layoutDock() {
        guard dockTicket != nil, panel.isHidden, isReleasedForDock, edgeKeyboard != .visible,
              let frame = dockCandidateFrame else {
            dockEdge.isHidden = true
            return
        }
        dockEdge.frame = frame
        dockEdge.isHidden = false
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutDock()
    }

    func foregroundChanged() {
        if let session = session, !session.remainsForeground {
            end("前台场景改变，实验已结束；不会自动重新挂载。")
        }
    }

    fileprivate func report(_ message: String) { status.text = message }

    func refreshEnvironment() { refreshButtons() }

    func blockOverlayCleanup(_ message: String) {
        if let token = state.beginCancellation() { _ = state.finishCancellation(token, succeeded: false) }
        status.text = message
        refreshButtons()
    }

    private func refreshButtons() {
        let permitted = PDProbeRuntime.permitsInteraction(self)
        let mounted = state.phase == .attached
        startButton.isHidden = mounted
        startButton.isEnabled = permitted && state.phase == .idle && PDProbeRuntime.canMount(self)
        activeEdge.isHidden = !permitted || blocksRevealInput || !(mounted || (rotationOffer != nil && state.phase == .idle))
        focusButton.isEnabled = !isFiles && permitted && mounted && !blocksRevealInput && !state.focusRequested
        stopButton.isEnabled = state.phase != .idle
    }

    private func keyboard(_ note: Notification) {
        precondition(Thread.isMainThread)
        if note.name == UIResponder.keyboardDidHideNotification {
            keyboardEnvironment.recordHidden()
        } else {
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            keyboardEnvironment.recordFrame(frame)
        }
        edgeConfirmation = nil
        panel.accessibilityValue = keyboardEnvironment.accessibilitySummary
        if dockTicket != nil { layoutDock() }
        // Notification rectangles are global hints, not proven outside-card
        // occlusion. No focus, native setter, or restore work is scheduled here.
        if state.phase == .attached && session != nil { view.setNeedsLayout() }
    }

    private func layoutControls() {
        let width = view.bounds.width
        panel.frame = CGRect(x: 12, y: max(54, view.safeAreaInsets.top) + 4,
                             width: max(0, width - 24), height: 132)
        let edgeWidth: CGFloat = 104
        activeEdge.frame = CGRect(x: panel.bounds.midX - edgeWidth / 2, y: 0, width: edgeWidth, height: 34)
        titleLabel.frame = CGRect(x: 12, y: 8, width: max(0, activeEdge.frame.minX - 18), height: 24)
        closeButton.frame = CGRect(x: panel.bounds.width - 56, y: 0, width: 52, height: 40)
        status.frame = CGRect(x: 12, y: 34, width: panel.bounds.width - 24, height: 48)
        let buttons = isFiles ? [startButton, stopButton] : [startButton, focusButton, stopButton]
        let cellWidth = (panel.bounds.width - 16) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: 8 + CGFloat(index) * cellWidth, y: 88, width: cellWidth, height: 40)
        }
        layoutDock()
    }

    private func layoutSession(_ session: PDSceneSession) throws {
        guard !updatingSessionLayout, self.session === session,
              state.phase == .mounting || state.phase == .attached else { return }
        updatingSessionLayout = true
        defer { updatingSessionLayout = false }
        card.frame = view.bounds // One shared coordinate plane; no raw-host scaling.
        if state.phase == .attached && (!session.remainsForeground || !PDProbeRuntime.permitsInteraction(self) ||
            (view as? ProbeRootView)?.identityLost != false) {
            throw NSError(domain: "com.tsangbaby.pandora.geometry", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "原生呈现关系已改变，需结束实验。"])
        }
        let top = panel.frame.maxY + 12
        let bottom = view.bounds.height - max(12, view.safeAreaInsets.bottom)
        let available = CGRect(x: 12, y: top, width: view.bounds.width - 24, height: max(0, bottom - top))
        // Only inspect live occluders after attachment; before it the original
        // native presentation still owns the layers and is not outside evidence.
        let outside = state.phase == .attached ?
            ProbeKeyboardMonitor.outsideKeyboard(in: view, hostedView: session.hostedView).frames : []
        let frame: CGRect
        switch ProbeKeyboardLayout.hostedScene(source: session.sourceSize, available: available,
                                               outsideKeyboardFrames: outside) {
        case .present(let value): frame = value
        case .returnToNative:
            throw NSError(domain: "com.tsangbaby.pandora.geometry", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: isFiles ?
                            "已观察到卡外键盘遮挡，已结束实验；请在原生文件界面继续操作。" :
                            "已观察到卡片外键盘遮挡，实验已结束；请在原生备忘录继续输入。"])
        case .insufficientSpace:
            throw NSError(domain: "com.tsangbaby.pandora.geometry", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "可用空间不足，需结束实验；不会缩到无法输入。"])
        }
        // Do not re-publish an unchanged, still-correct hostTransformer merely
        // for a keyboard notification. Actual native geometry drift is checked.
        if laidOutSession === session && appliedContentFrame == frame, let host = session.hostedView {
            let actual = host.convert(host.bounds, to: card)
            if ProbeKeyboardLayout.isFiniteRect(actual) &&
                abs(actual.minX - frame.minX) <= 0.5 && abs(actual.minY - frame.minY) <= 0.5 &&
                abs(actual.width - frame.width) <= 0.5 && abs(actual.height - frame.height) <= 0.5 { return }
        }
        try session.update(frame: frame)
        guard self.session === session, state.phase == .mounting || state.phase == .attached else { return }
        laidOutSession = session
        appliedContentFrame = frame
        cardMotion?.geometryChanged(to: view.convert(frame, from: card))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutControls()
        guard let session = session else { return }
        do { try layoutSession(session) }
        catch { end(error.localizedDescription) }
    }

    deinit { for token in keyboardObservers { NotificationCenter.default.removeObserver(token) } }
}

@MainActor
@objc(PDProbeRuntime)
final class PDProbeRuntime: NSObject {
    private static let shared = PDProbeRuntime()
    private var root: ProbeController?
    private var lease: PDOverlayLease?
    private var armed: (target: PDProbeTarget, deadline: TimeInterval)?
    private var rotation = WorkspaceRotation()
    private var workspaceDock = WorkspaceDock()
    private weak var preparingRoot: ProbeController?
    private var closingRequested = false
    private var retiringControls = false
    private var checkingDockRestore = false

    @objc static func showControls() { arm(.notes) }
    @objc static func showFilesControls() { arm(.files) }

    private static func arm(_ target: PDProbeTarget) {
        precondition(Thread.isMainThread)
        guard shared.root == nil, shared.preparingRoot == nil, !shared.retiringControls else { return }
        shared.rotation.cancel() // A new, explicit standalone choice replaces a pending route.
        shared.armed = (target, ProcessInfo.processInfo.systemUptime + 30)
        foregroundChanged()
    }

    private func presentControls(_ target: PDProbeTarget, offer: WorkspaceRotation.Ticket? = nil) {
        armed = nil
        guard rotation.permitsMount(target.rotationMember, offer: offer) else { return }
        let candidate = ProbeController(target: target, rotationOffer: offer)
        preparingRoot = candidate
        closingRequested = false
        defer {
            preparingRoot = nil
            if root == nil {
                if let offer { rotation.discardOffer(offer) }
                closingRequested = false
            }
        }
        do {
            try PDOverlayLease.finishPending()
            guard !closingRequested else { return }
            let lease = try PDOverlayLease.attach(controller: candidate, target: target, onInvalidation: { [weak candidate] in
                guard let candidate, PDProbeRuntime.shared.root === candidate ||
                      PDProbeRuntime.shared.preparingRoot === candidate else { return }
                PDProbeRuntime.stopControls()
            })
            guard !closingRequested, lease.valid, !closingRequested,
                  rotation.permitsMount(target.rotationMember, offer: offer) else {
                try lease.finish()
                return
            }
            self.root = candidate
            self.lease = lease
            candidate.refreshEnvironment()
        } catch {
            NSLog("[Pandora] Native controls refused: %@", error.localizedDescription)
        }
    }

    @objc static func stopControls() {
        precondition(Thread.isMainThread)
        let runtime = shared
        runtime.armed = nil
        runtime.rotation.cancel()
        runtime.workspaceDock.cancel()
        runtime.root?.clearDock()
        _ = runtime.retireControls("实验已结束；请检查原生画面、滚动和输入是否恢复。")
    }

    @discardableResult
    static func rotate(from root: ProbeController) -> Bool {
        precondition(Thread.isMainThread)
        let runtime = shared
        guard root.canUseHeader, permitsInteraction(root), runtime.workspaceDock.phase == .idle,
              let ticket = runtime.rotation.beginReturn(from: root.member) else { return false }
        runtime.armed = nil
        let retired = runtime.retireControls("已移除实验宿主，正在核对原生归还。", verifyNativeReturn: true)
        let verified = retired && PDProbeCanPresent(root.target)
        guard runtime.rotation.finishReturn(ticket, verified: verified, now: ProcessInfo.processInfo.systemUptime) else { return false }
        UIAccessibility.post(notification: .announcement,
                             argument: "已交还\(ticket.source.appName)，请在三十秒内手动打开\(ticket.destination.appName)。")
        return true
    }

    static func dock(from root: ProbeController) -> Bool {
        let runtime = shared
        guard root.canUseHeader, permitsInteraction(root), let lease = runtime.lease,
              runtime.rotation.phase == .idle, runtime.rotation.lastMounted == root.member else { return false }
        guard root.dockCandidateFrame != nil else {
            root.report("当前底部没有合适的停靠空间，工作卡保持打开。")
            return false
        }
        guard let ticket = runtime.workspaceDock.beginReturn(root.member) else { return false }
        runtime.armed = nil
        runtime.closingRequested = true
        runtime.retiringControls = true
        let released = root.end("已移除实验宿主，正在核对原生归还。")
        let verified = released && lease.nativeReturnConfirmed
        runtime.retiringControls = false
        // A reentrant stop or foreground change revokes the ticket before any tab is shown.
        guard runtime.workspaceDock.phase == .returning(ticket) else {
            if released { _ = runtime.retireControls("已取消停靠，不会自动恢复。") }
            return false
        }
        guard runtime.workspaceDock.completeReturn(ticket, nativeVerified: verified) else {
            if released { root.blockOverlayCleanup("未能确认原生归还，未停靠。请关闭面板后检查当前 App。") }
            return false
        }
        guard runtime.root === root, runtime.lease === lease, root.dockCandidateFrame != nil,
              root.edgeKeyboard != .visible else {
            stopControls()
            return false
        }
        runtime.closingRequested = false
        root.showDock(ticket)
        UIAccessibility.post(notification: .announcement, argument: "工作卡已收起。从底部短边上滑可展开。")
        return true
    }

    static func hasParkedDock(_ root: ProbeController, ticket: WorkspaceDock.Ticket) -> Bool {
        let runtime = shared
        return runtime.root === root && !runtime.closingRequested && !runtime.retiringControls &&
            runtime.workspaceDock.isParked(ticket)
    }

    static func canRestoreDock(_ root: ProbeController, ticket: WorkspaceDock.Ticket) -> Bool {
        return root.dockTicket == ticket && root.isReleasedForDock && root.dockCandidateFrame != nil &&
            root.dockHitFrame != nil && root.edgeKeyboard != .visible &&
            hasParkedDock(root, ticket: ticket) && permitsInteraction(root)
    }

    static func restoreDock(from root: ProbeController, ticket: WorkspaceDock.Ticket) -> Bool {
        let runtime = shared
        guard !runtime.checkingDockRestore, canRestoreDock(root, ticket: ticket),
              let lease = runtime.lease else { return false }
        runtime.checkingDockRestore = true
        defer { runtime.checkingDockRestore = false }
        let verified = lease.nativeReturnConfirmed
        guard runtime.root === root, runtime.lease === lease, canRestoreDock(root, ticket: ticket),
              runtime.workspaceDock.beginRestore(ticket, member: root.member, nativeVerified: verified) else {
            if runtime.root === root, root.dockTicket == ticket, !verified {
                stopControls()
                UIAccessibility.post(notification: .announcement, argument: "原生场景已变，未展开工作卡。")
            }
            return false
        }
        let restored = root.restoreFromDock()
        if !restored {
            runtime.workspaceDock.discardRestore(ticket)
            root.clearDock()
            root.refreshEnvironment()
        }
        return restored
    }

    @discardableResult
    private func retireControls(_ message: String, verifyNativeReturn: Bool = false) -> Bool {
        closingRequested = true
        // No nested retirement, and no cleanup while native containment is still preparing.
        guard !retiringControls, preparingRoot == nil else { return false }
        retiringControls = true
        defer { retiringControls = false }
        let root = self.root
        let lease = self.lease
        guard root?.end(message) ?? true else { return false }
        if verifyNativeReturn, lease?.nativeReturnConfirmed != true {
            root?.blockOverlayCleanup("未能确认原生归还，未安排轮换。请关闭面板后检查当前 App。")
            return false
        }
        do {
            try lease?.finish()
            try PDOverlayLease.finishPending()
            self.root = nil
            self.lease = nil
            closingRequested = false
            return true
        } catch {
            root?.blockOverlayCleanup("控制层清理未确认：\(error.localizedDescription)")
            return false
        }
    }

    static func permitsInteraction(_ root: ProbeController) -> Bool {
        let runtime = shared
        guard runtime.root === root, !runtime.closingRequested, !runtime.retiringControls else { return false }
        let valid = runtime.lease?.valid == true
        return ProbeAdmission.permits(published: runtime.root === root, closing: runtime.closingRequested,
                                      overlayValid: valid)
    }

    static func canMount(_ root: ProbeController) -> Bool {
        return shared.rotation.permitsMount(root.member, offer: root.rotationOffer) &&
            shared.workspaceDock.permitsMount(root.member, restore: root.dockTicket)
    }

    static func interactiveOverlay(for root: ProbeController) -> PDOverlayLease? {
        return permitsInteraction(root) && canMount(root) ? shared.lease : nil
    }

    static func recordMount(for root: ProbeController, generation: UInt64) -> Bool {
        let runtime = shared
        guard permitsInteraction(root), root.state.phase == .attached, root.state.generation == generation else { return false }
        var rotation = runtime.rotation
        var dock = runtime.workspaceDock
        guard rotation.recordMount(root.member, offer: root.rotationOffer),
              dock.completeMount(root.member, restore: root.dockTicket) else { return false }
        runtime.rotation = rotation
        runtime.workspaceDock = dock
        return true
    }

    static func discardMountOffer(for root: ProbeController) {
        guard shared.root === root else { return }
        if let offer = root.rotationOffer { shared.rotation.discardOffer(offer) }
        if let ticket = root.dockTicket { shared.workspaceDock.discardRestore(ticket) }
    }

    static func isClosing(_ root: ProbeController) -> Bool {
        return shared.root === root && shared.closingRequested
    }

    static func resumeAfterNativeOperation(_ root: ProbeController) {
        // Resume the first deferred close even after foreground/root loss.
        // A retirement already attempted never schedules its own failed retry.
        guard ProbeAdmission.resumesClose(published: shared.root === root, closing: shared.closingRequested,
                                          cleanupEligible: shared.lease?.allowsDeferredFinish == true) else { return }
        DispatchQueue.main.async { [weak root] in
            guard let root = root, isClosing(root), shared.lease?.allowsDeferredFinish == true else { return }
            stopControls()
        }
    }

    static func rootDetached(_ root: ProbeController) {
        DispatchQueue.main.async { [weak root] in
            // Intentional removal during our own retirement isn't a new cancel.
            guard let root = root, shared.root === root, !shared.retiringControls else { return }
            stopControls()
        }
    }

    @objc static func foregroundChanged() {
        precondition(Thread.isMainThread)
        let runtime = shared
        if runtime.retiringControls {
            if case .returning = runtime.workspaceDock.phase { runtime.workspaceDock.cancel() }
            return
        }
        if let root = runtime.root {
            if runtime.lease?.valid == true { root.foregroundChanged() }
            else { stopControls() }
        } else if let preparing = runtime.preparingRoot {
            if !PDProbeCanPresent(preparing.target) {
                runtime.closingRequested = true
                runtime.rotation.cancel()
            }
        } else if let destination = runtime.rotation.waitingFor {
            let foreground = PDProbeCanPresent(destination.probeTarget) ? destination : nil
            if let offer = runtime.rotation.offer(whenForeground: foreground, now: ProcessInfo.processInfo.systemUptime) {
                // This attaches only the bound controls. No presenter is created
                // until the receiving App's explicit mount action.
                runtime.presentControls(destination.probeTarget, offer: offer)
            }
        } else if let armed = runtime.armed {
            if ProcessInfo.processInfo.systemUptime >= armed.deadline { runtime.armed = nil }
            else if PDProbeCanPresent(armed.target) { runtime.presentControls(armed.target) }
        }
    }
}
