import SwiftUI
import UIKit

extension View {
    /// Goes on the content of a `.refreshable` ScrollView: pulling to
    /// refresh then shows `HuddleSpinner` instead of the system's spinner.
    /// Its dots come in as the pull goes on and turn once it's refreshing.
    func huddleRefreshSpinner() -> some View {
        background(RefreshSpinnerHook())
    }
}

/// How far the pull has come (0 to 1) and whether it's refreshing.
@MainActor
@Observable
private final class RefreshProgress {
    var pulled: Double = 0
    var isRefreshing = false
}

private struct RefreshIndicator: View {
    let progress: RefreshProgress

    var body: some View {
        if progress.isRefreshing {
            HuddleSpinner(size: 28, label: "Refreshing")
        } else {
            HuddleSpinner(size: 28, label: nil, pulled: progress.pulled)
        }
    }
}

/// Finds the scroll view it's in and the refresh control `.refreshable`
/// gave it, makes the system's spinner invisible, and puts the huddle
/// spinner in the control: UIKit places the control (above a large title,
/// or under an inline one), so the spinner lands where the system's would.
/// If there's no control to find, nothing changes.
private struct RefreshSpinnerHook: UIViewRepresentable {
    func makeUIView(context: Context) -> HookView { HookView() }
    func updateUIView(_ view: HookView, context: Context) { view.setNeedsLayout() }

    final class HookView: UIView {
        /// Marks the spinner's view in a control, so it's never added twice.
        private static let tag = 0x4855_4444

        private let progress = RefreshProgress()
        private weak var control: UIRefreshControl?
        private var host: UIHostingController<RefreshIndicator>?
        private var offsetObservation: NSKeyValueObservation?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        // The control can arrive after the content is first laid out.
        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }

        private func attach() {
            guard window != nil, let scrollView = enclosingScrollView(),
                  let control = scrollView.refreshControl, control !== self.control else { return }
            self.control = control
            control.tintColor = .clear
            control.subviews.filter { $0.tag == Self.tag }.forEach { $0.removeFromSuperview() }

            let host = UIHostingController(rootView: RefreshIndicator(progress: progress))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.tag = Self.tag
            host.view.translatesAutoresizingMaskIntoConstraints = false
            control.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.centerXAnchor.constraint(equalTo: control.centerXAnchor),
                host.view.centerYAnchor.constraint(equalTo: control.centerYAnchor),
                host.view.widthAnchor.constraint(equalToConstant: 32),
                host.view.heightAnchor.constraint(equalToConstant: 32),
            ])
            self.host = host

            offsetObservation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.update(scrollView) }
            }
        }

        private func update(_ scrollView: UIScrollView) {
            guard let control else { return }
            // SwiftUI may tint the control again; keep its own spinner hidden.
            if control.tintColor != .clear { control.tintColor = .clear }
            let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            // All four dots are in well before the refresh starts, so it
            // turns straight on from them.
            progress.pulled = min(1, max(0, Double(pull) / 64))
            progress.isRefreshing = control.isRefreshing
        }

        private func enclosingScrollView() -> UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView { return scrollView }
                view = current.superview
            }
            return nil
        }
    }
}
