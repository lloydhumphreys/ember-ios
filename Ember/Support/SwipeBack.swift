import SwiftUI
import UIKit

extension View {
    /// Keeps the edge swipe back on a screen that hides the system's Back for its own: UIKit turns
    /// the swipe off with the button, and a screen you can only leave by reaching for the corner
    /// is a step backwards.
    func keepsSwipeBack() -> some View {
        background(SwipeBack().frame(width: 0, height: 0))
    }
}

private struct SwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    /// Stands in as the swipe's delegate while the screen is showing, and hands it back as it
    /// goes: to a pop, or to a screen pushed over it, which has a Back of its own.
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var original: UIGestureRecognizerDelegate?
        private weak var swipe: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let swipe = navigationController?.interactivePopGestureRecognizer,
                  swipe.delegate !== self else { return }
            original = swipe.delegate
            self.swipe = swipe
            swipe.delegate = self
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if let swipe, swipe.delegate === self { swipe.delegate = original }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
