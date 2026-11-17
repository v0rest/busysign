import BusySignCore
import SwiftUI

/// The bar at the bottom of Settings and of the Meetings window while changes are staged
/// (`AppModel.staged`): what Apply would do (`StatusText.applyBar`), then Revert and Apply. Apply is off until the
/// preview of exactly the staged changes has landed with counts Apply can act on, for what Apply would clear now and
/// worked out today (`AppModel.canApplyStagedChanges`); the text says `Working out…` meanwhile, the reason while the
/// preview could not be worked out, and the counts with the reason while a calendar's empty read is held, until a
/// later preview can be applied. A Look ahead or short name typed in Settings is staged keystroke by keystroke, so
/// the bar comes while typing and each keystroke that changes what is staged greys Apply until its preview lands. No
/// key equivalent: Return in a field of the window must never apply.
struct ApplyBar: View {
    @ObservedObject var model: AppModel
    /// Ends editing in Settings before Apply from either window (`SettingsWindowController.endEditing`): clicking a
    /// button does not take the focus from a field. What is typed there is staged already, so it stages nothing and
    /// Apply applies what this bar previewed.
    let endEditing: @MainActor () -> Void
    /// Revert from either window, with what is typed in Settings (`SettingsWindowController.revertStagedChanges`):
    /// ends editing there, reverts, then drops what is left, a Check every not committed yet included.
    let revert: @MainActor () -> Void
    /// Bumped by each click on Live in Settings refused while changes are staged (`LiveSwitch.waitsForApply`): the
    /// bar's background flashes the accent colour for about a second, from the start again on every click. Never
    /// bumped in the Meetings window.
    var flash = 0
    @State private var highlighted = false
    @State private var highlightEnd: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            // Wraps rather than truncates, so no removal count is cut off.
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Revert") { revert() }
            .fixedSize()
            Button("Apply") {
                endEditing()
                model.applyStagedChanges()
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(!model.canApplyStagedChanges)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background { Color.accentColor.opacity(highlighted ? 0.3 : 0) }
        .background(.bar)
        // On a change only: a bar that comes back later must not flash for an old click.
        .onChange(of: flash) { highlight() }
        .onDisappear { highlightEnd?.cancel() }
    }

    /// Calendars by their shown names, in the applied selection's order, then the ones ticked anew.
    private var text: String {
        StatusText.applyBar(changes: model.stagedChangeCount, preview: model.preview,
                            workingOut: model.previewInFlight,
                            order: model.applied.selected + model.effective.selected, name: model.shortName)
    }

    /// Turns the highlight on and off again a second later; a newer click restarts the second. With Reduce Motion
    /// it comes and goes without fading.
    private func highlight() {
        highlightEnd?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { highlighted = true }
        highlightEnd = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.4)) { highlighted = false }
        }
    }
}
