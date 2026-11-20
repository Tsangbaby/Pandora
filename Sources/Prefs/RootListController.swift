import UIKit
import CoreFoundation

@objc(PDProbeSettings)
final class RootListController: PSViewController {
    override init() { super.init() }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pandora"
        view.backgroundColor = .systemGroupedBackground
        let instructions = UILabel()
        instructions.font = .preferredFont(forTextStyle: .body)
        instructions.adjustsFontForContentSizeCategory = true
        instructions.numberOfLines = 0
        instructions.text = "单 Scene 实验 · 仅 iOS 15.4.1。选择备忘录或文件，30 秒内回到所选 App 并手动挂载。请使用非敏感内容；文件测试仅验证显示、滚动、点击和归还。"
        let arm = UIButton(type: .system)
        arm.setTitle("准备备忘录实验", for: .normal)
        arm.addTarget(self, action: #selector(prepareProbe), for: .touchUpInside)
        let files = UIButton(type: .system)
        files.setTitle("准备文件实验", for: .normal)
        files.addTarget(self, action: #selector(prepareFilesProbe), for: .touchUpInside)
        let stop = UIButton(type: .system)
        stop.setTitle("停止实验／取消准备", for: .normal)
        stop.addTarget(self, action: #selector(stopProbe), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [instructions, arm, files, stop])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            arm.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            files.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stop.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    @objc private func prepareProbe() {
        prepare(app: "备忘录", notification: "com.tsangbaby.pandora.probe.show")
    }

    @objc private func prepareFilesProbe() {
        prepare(app: "文件", notification: "com.tsangbaby.pandora.probe.show-files")
    }

    private func prepare(app: String, notification: String) {
        post(notification)
        let alert = UIAlertController(title: "准备\(app)实验", message: "请在 30 秒内手动回到竖屏「\(app)」。点实验面板的「挂载\(app)」才开始。若没有面板，请记录情况，不要反复尝试。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    @objc private func stopProbe() { post("com.tsangbaby.pandora.probe.stop") }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString), nil, nil, true)
    }
}
