import UIKit

@MainActor final class KeyboardView: UIView {
    enum Key { case text(String), backspace, nextKeyboard }
    var onKey: ((Key) -> Void)?
    var onStop: (() -> Void)?
    private let stack = UIStackView()
    private let status = UILabel()
    private let stop = UIButton(type: .system)
    private var shifted = false
    private var numbers = false
    private var symbols = false
    private var rows: [UIStackView] = []
    private(set) var globeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        let header = UIStackView()
        header.spacing = 8
        header.alignment = .center
        status.font = .preferredFont(forTextStyle: .caption1)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 2
        status.text = "Open Speech Keyboard to start listening"
        status.accessibilityTraits = .updatesFrequently
        header.addArrangedSubview(status)
        stop.setTitle("Stop", for: .normal)
        stop.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        stop.accessibilityLabel = "Stop listening"
        header.addArrangedSubview(stop)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(header)
        buildRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(_ text: String, canStop: Bool) {
        if status.text != text { status.text = text }
        stop.isEnabled = canStop
    }

    private func button(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .label
        config.baseBackgroundColor = .tertiarySystemBackground
        config.cornerStyle = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 1, bottom: 4, trailing: 1)
        button.configuration = config
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return button
    }

    private func buildRows() {
        rows.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = []
        let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let digits = ["1234567890", "-/:;()$&@\"", ".,?!'[]"]
        let extra = ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'`"]
        for (index, keys) in (numbers ? (symbols ? extra : digits) : letters).enumerated() {
            let row = UIStackView()
            row.spacing = 5
            row.distribution = .fillEqually
            if index == 2 {
                row.addArrangedSubview(button(numbers ? (symbols ? "123" : "#+=") : (shifted ? "⇧●" : "⇧")) { [weak self] in
                    guard let self else { return }
                    if numbers { symbols.toggle() } else { shifted.toggle() }
                    buildRows()
                })
            }
            for character in keys {
                let text = shifted && !numbers ? String(character).uppercased() : String(character)
                row.addArrangedSubview(button(text) { [weak self] in
                    self?.onKey?(.text(text))
                    if self?.shifted == true { self?.shifted = false; self?.buildRows() }
                })
            }
            if index == 2 {
                let delete = button("⌫") { [weak self] in self?.onKey?(.backspace) }
                delete.accessibilityLabel = "Delete"
                row.addArrangedSubview(delete)
            }
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        let bottom = UIStackView()
        bottom.spacing = 6
        let mode = button(numbers ? "ABC" : "123") { [weak self] in self?.numbers.toggle(); self?.buildRows() }
        globeButton = button("🌐") { [weak self] in self?.onKey?(.nextKeyboard) }
        globeButton.accessibilityLabel = "Next keyboard"
        let space = button("space") { [weak self] in self?.onKey?(.text(" ")) }
        let enter = button("return") { [weak self] in self?.onKey?(.text("\n")) }
        for button in [mode, globeButton, space, enter] { bottom.addArrangedSubview(button) }
        mode.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.15).isActive = true
        globeButton.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.13).isActive = true
        enter.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.2).isActive = true
        rows.append(bottom)
        stack.addArrangedSubview(bottom)
    }
}
