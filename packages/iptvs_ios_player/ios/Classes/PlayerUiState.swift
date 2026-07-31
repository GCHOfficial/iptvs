import Foundation

/// The observable box around ``PlayerChromeState``.
///
/// This is the whole of the iOS counterpart to Android's `PlayerUiState` class
/// that *isn't* already in `Core`. Compose gets change propagation from
/// `mutableStateOf` per field; UIKit has nothing equivalent, so the split here
/// is deliberately the other way round from Kotlin's:
///
/// - **`PlayerChromeState` (Core, a value type)** holds every field *and* every
///   derived label/visibility rule, so `swift test` covers the behaviour on the
///   CI host with no simulator — the same reason `ReconnectPolicy` and
///   `PlayerBackPolicy` live there.
/// - **This class** is the mutable identity the view controller holds, and the
///   single choke point where "something changed" becomes "re-render".
///
/// Two properties matter and are worth stating plainly:
///
/// 1. **One mutation, one render.** `value` is a plain stored property with a
///    `didSet`, so `state.value.isPlaying = true` notifies exactly once. A
///    sequence of related edits goes through ``batch(_:)`` so a progress tick
///    that moves four fields still renders once.
/// 2. **No-op writes don't render.** `PlayerChromeState` is `Equatable` and the
///    `didSet` diffs, so the 2 Hz progress tick stops at the box whenever
///    nothing actually moved (a paused player, or a live stream whose position
///    label hasn't ticked over). That is the UIKit equivalent of Compose
///    skipping recomposition, and it is what makes a full re-render on every
///    change an acceptable design rather than a busy loop.
///
/// Not thread-safe, and deliberately not made so: every writer is a UIKit
/// callback or an `AvPlayerEngine` callback that already hops to the main
/// queue (`DispatchQueue.main.async` in its KVO observers).
final class PlayerUiState {
  /// Called after any change that actually moved the state. Set by
  /// `IptvsPlayerViewController` in its initialiser.
  var onChange: ((PlayerChromeState) -> Void)?

  private(set) var previous: PlayerChromeState

  var value: PlayerChromeState {
    didSet {
      guard value != oldValue else { return }
      previous = oldValue
      onChange?(value)
    }
  }

  init(_ initial: PlayerChromeState) {
    value = initial
    previous = initial
  }

  /// Applies several edits as one change, so the render runs once at the end
  /// rather than once per field.
  ///
  /// Uses a local copy rather than mutating `value` in place: an in-place
  /// mutation of a stored property with an observer fires `didSet` per
  /// statement, which is exactly what this exists to avoid.
  func batch(_ mutate: (inout PlayerChromeState) -> Void) {
    var draft = value
    mutate(&draft)
    value = draft
  }
}
