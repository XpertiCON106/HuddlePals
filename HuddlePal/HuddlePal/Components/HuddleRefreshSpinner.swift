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

/// How far the pull has come (0 to 1) and whether the spinner turns.
@MainActor
@Observable
private final class RefreshProgress {
    var pulled: Double = 0
    /// From the moment a pull sets a refresh off until the content is back
    /// in place: it keeps turning while a thumb holds the pull, however
    /// soon the refresh is done.
    var isTurning = false
}

private struct RefreshIndicator: View {
    let progress: RefreshProgress

    var body: some View {
        if progress.isTurning {
            HuddleSpinner(size: 28, label: "Refreshing")
        } else {
            HuddleSpinner(size: 28, label: nil, pulled: progress.pulled)
        }
    }
}

/// Finds the scroll view it's in and the refresh control `.refreshable`
/// gave it, makes the system's spinner invisible, and shows the huddle
/// spinner over the control: UIKit places the control (above a large title,
/// or under an inline one), so the spinner lands where the system's would.
/// Under a large title UIKit keeps the control in the navigation bar, in a
/// container it fades out the moment a refresh ends, thumb still holding
/// the pull or not; there the spinner goes beside that container instead of
/// in the control, so it stays until the content is back in place. If
/// there's no control to find, nothing changes.
private struct RefreshSpinnerHook: UIViewRepresentable {
    func makeUIView(context: Context) -> HookView { HookView() }
    func updateUIView(_ view: HookView, context: Context) { view.setNeedsLayout() }

    final class HookView: UIView {
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
            if window == nil {
                // Off screen: the spinner may sit outside this view (in the
                // navigation bar the next screen shares), so it goes too.
                host?.view.removeFromSuperview()
            } else {
                attach()
            }
        }

        // The control can arrive after the content is first laid out.
        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }

        private func attach() {
            guard window != nil, let scrollView = enclosingScrollView(),
                  let control = scrollView.refreshControl else { return }
            if control !== self.control {
                self.control = control
                control.tintColor = .clear
                offsetObservation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated { self?.update(scrollView) }
                }
            }
            update(scrollView)
        }

        private func update(_ scrollView: UIScrollView) {
            guard let control else { return }
            // SwiftUI may tint the control again; keep its own spinner hidden.
            if control.tintColor != .clear { control.tintColor = .clear }
            let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            // All four dots are in well before the refresh starts, so it
            // turns straight on from them.
            progress.pulled = min(1, max(0, Double(pull) / 64))
            // Once a refresh starts it turns until the content is back in
            // place, however soon the refresh is done.
            if control.isRefreshing {
                progress.isTurning = true
            } else if progress.pulled == 0 {
                progress.isTurning = false
            }
            place(over: control)
        }

        /// The spinner over the control's middle: in the control when it's in
        /// the scroll view, beside its container when UIKit keeps it in the
        /// navigation bar.
        private func place(over control: UIRefreshControl) {
            guard let container = control.superview else { return }
            let holder = container is UIScrollView ? control : (container.superview ?? container)
            let spinner = spinnerView()
            if spinner.superview !== holder { holder.addSubview(spinner) }
            spinner.center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: holder)
            spinner.isHidden = progress.pulled == 0 && !progress.isTurning
        }

        private func spinnerView() -> UIView {
            if let host { return host.view }
            let host = UIHostingController(rootView: RefreshIndicator(progress: progress))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
            self.host = host
            return host.view
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
