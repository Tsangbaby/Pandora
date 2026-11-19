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
        instructions.text = "单 Scene 实验 · 仅 iOS 15.4.1。先在备忘录准备一篇非敏感测试笔记，再回到此页点「准备实验」。30 秒内返回备忘录并确认挂载；不会自动挂载或输入。"
        let arm = UIButton(type: .system)
        arm.setTitle("准备实验", for: .normal)
        arm.addTarget(self, action: #selector(prepareProbe), for: .touchUpInside)
        let stop = UIButton(type: .system)
        stop.setTitle("停止实验／取消准备", for: .normal)
        stop.addTarget(self, action: #selector(stopProbe), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [instructions, arm, stop])
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
            stop.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    @objc private func prepareProbe() {
        post("com.tsangbaby.pandora.probe.show")
        let alert = UIAlertController(title: "准备 Pandora 实验", message: "现在返回竖屏备忘录。在实验面板点「挂载备忘录」才开始。若没有出现面板，请停止测试并记录情况。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    @objc private func stopProbe() { post("com.tsangbaby.pandora.probe.stop") }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString), nil, nil, true)
    }
}
