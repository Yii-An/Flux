import SwiftUI
import AppKit

struct SmallProgressView: NSViewRepresentable {
    var isAnimating: Bool = true

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        if isAnimating {
            nsView.startAnimation(nil)
        } else {
            nsView.stopAnimation(nil)
        }
    }
}
