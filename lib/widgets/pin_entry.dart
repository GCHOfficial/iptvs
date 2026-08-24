import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/profile_pin.dart';
import '../theme.dart';
import 'focusable_card.dart';

/// Profile-PIN entry: one dialog, two jobs — unlocking a profile and choosing a
/// new PIN for one.
///
/// **Why an in-app keypad rather than a text field.** The primary device is a
/// television with a remote. A `TextField` there opens the platform IME, which
/// on Android TV is a full alphabetic keyboard that traps D-pad focus — the
/// exact reason this app has `TvTextField` at all. Four digits deserve better
/// than that: a 3x4 pad of ordinary focus targets is arrow-navigable by
/// construction, tappable on a phone, and needs no IME on any surface. Desktop
/// is the exception ([pinKeypadForPlatform]): a keyboard is always attached
/// there, so the pad would be a mouse-only detour around keys already under the
/// user's fingers.
///
/// Hardware digits work on **every** surface regardless. Many TV remotes carry
/// a number pad, and a key event from one bubbles from whichever pad button
/// holds focus up to this dialog's own handler — so the pad is a floor, not a
/// ceiling.

/// Whether [platform] gets the on-screen keypad.
///
/// Pure and exported so a widget test can sweep it without driving a real
/// platform channel. Desktop types; everything else taps or arrows.
bool pinKeypadForPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => false,
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => true,
};

/// Consecutive wrong PINs before entry stops being accepted for a while.
///
/// A four-digit PIN has ten thousand values, so a cooldown is the only thing
/// that makes guessing tedious rather than quick: five tries per [kPinLockout]
/// is about seventeen hours of uninterrupted button-pressing for an exhaustive
/// search. It is not defence against someone holding the verifier — nothing at
/// this key length is — it is defence against the person standing in front of
/// the television.
///
/// **The count therefore cannot live in the dialog's state**, which is what it
/// did first: closing the dialog and re-selecting the profile reset it, so four
/// tries and a Back press bought four more, indefinitely, and the cooldown was
/// decoration. It lives in [_attempts] instead — keyed per profile, for the
/// life of the process. A restart still clears it, which is the honest limit of
/// a device-side gate: someone willing to kill the app between every fifth
/// guess is past what four digits was ever going to stop.
const int kPinAttemptsBeforeLockout = 5;

/// How long entry is refused after [kPinAttemptsBeforeLockout] misses.
const Duration kPinLockout = Duration(seconds: 30);

/// Wrong-PIN history, keyed by verifier (i.e. per profile) and outliving any
/// one dialog. See [kPinAttemptsBeforeLockout].
final Map<String, _Attempts> _attempts = {};

class _Attempts {
  int misses = 0;
  DateTime? lockedUntil;
}

/// Forget every profile's wrong-PIN history. Tests only — a cooldown that
/// leaked between test cases would make them order-dependent.
@visibleForTesting
void debugResetPinAttempts() => _attempts.clear();

/// Ask for [profileName]'s PIN and check it against [verifier].
///
/// Returns true only on a correct entry. Cancelling — or a verifier this build
/// cannot read — returns false, which every caller must treat as "stay out".
Future<bool> promptUnlockProfile(
  BuildContext context, {
  required String profileName,
  required String verifier,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PinDialog(profileName: profileName, verifier: verifier),
  );
  return ok == true;
}

/// Ask for a new PIN for [profileName], twice, and return it once both entries
/// agree. Null when the user backs out.
Future<String?> promptNewProfilePin(
  BuildContext context, {
  required String profileName,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _PinDialog(profileName: profileName),
);

class _PinDialog extends StatefulWidget {
  final String profileName;

  /// Non-null for the unlock job; null means "choose a new PIN".
  final String? verifier;

  const _PinDialog({required this.profileName, this.verifier});

  bool get unlocking => verifier != null;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  String _entry = '';

  /// Create mode: the first entry, waiting to be confirmed.
  String? _firstEntry;

  String? _error;
  Timer? _cooldown;

  /// This profile's wrong-PIN history. Create mode has no verifier and no
  /// history — there is nothing to guess at.
  _Attempts get _history =>
      _attempts.putIfAbsent(widget.verifier ?? '', () => _Attempts());

  /// True when the stored verifier is one this build cannot parse — a PIN set
  /// by a newer version. The profile stays shut (see [verifyProfilePin]); the
  /// dialog says so instead of silently rejecting every correct entry.
  bool get _unreadable =>
      widget.unlocking && !isProfilePinVerifier(widget.verifier!);

  bool get _cooling {
    if (!widget.unlocking) return false;
    final until = _history.lockedUntil;
    return until != null && until.isAfter(DateTime.now());
  }

  int get _secondsLeft {
    final until = widget.unlocking ? _history.lockedUntil : null;
    return until == null
        ? 0
        : until.difference(DateTime.now()).inSeconds.clamp(0, 999);
  }

  @override
  void initState() {
    super.initState();
    // Reopened while a cooldown from an earlier dialog is still running: the
    // countdown has to keep counting down, or it reads as a dead number.
    if (_cooling) _startCooldownTicker();
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  void _startCooldownTicker() {
    _cooldown?.cancel();
    _cooldown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (!_cooling) t.cancel();
      setState(() {});
    });
  }

  void _append(String digit) {
    if (_unreadable || _cooling || _entry.length >= kProfilePinLength) return;
    setState(() {
      _entry += digit;
      _error = null;
    });
    if (_entry.length == kProfilePinLength) {
      // Give the frame with the last dot filled a chance to paint before the
      // dialog acts on it — otherwise a correct PIN dismisses with the entry
      // looking one digit short, and a wrong one clears before it was seen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit();
      });
    }
  }

  void _backspace() {
    if (_entry.isEmpty) return;
    setState(() {
      _entry = _entry.substring(0, _entry.length - 1);
      _error = null;
    });
  }

  void _submit() {
    if (_entry.length != kProfilePinLength || _cooling) return;
    final entered = _entry;
    if (widget.unlocking) {
      if (verifyProfilePin(entered, widget.verifier!)) {
        // The history is this profile's, not this dialog's, so a correct PIN
        // has to clear it — otherwise yesterday's near-misses cool down a user
        // who has just proved they know it.
        _attempts.remove(widget.verifier);
        Navigator.of(context).pop(true);
        return;
      }
      final history = _history;
      history.misses++;
      final cooling = history.misses >= kPinAttemptsBeforeLockout;
      setState(() {
        _entry = '';
        if (cooling) {
          history.misses = 0;
          history.lockedUntil = DateTime.now().add(kPinLockout);
          _error = null;
          _startCooldownTicker();
        } else {
          _error = 'Wrong PIN. Try again.';
        }
      });
      return;
    }
    // Choosing a new PIN: type it twice.
    if (_firstEntry == null) {
      setState(() {
        _firstEntry = entered;
        _entry = '';
        _error = null;
      });
      return;
    }
    if (_firstEntry == entered) {
      Navigator.of(context).pop(entered);
      return;
    }
    setState(() {
      _firstEntry = null;
      _entry = '';
      _error = 'Those did not match. Start again.';
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final digit = _digitFor(key);
    if (digit != null) {
      _append(digit);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _backspace();
      return KeyEventResult.handled;
    }
    // Enter/Escape are left alone: on a remote, Select belongs to whichever pad
    // button holds focus, and Back is the route's own.
    return KeyEventResult.ignored;
  }

  /// Both key rows a device might send: the number row and the numpad. Built
  /// once as a `static final` — `LogicalKeyboardKey` overrides `==`, so it
  /// cannot key a `const` map.
  static final Map<LogicalKeyboardKey, String> _digits = {
    LogicalKeyboardKey.digit0: '0',
    LogicalKeyboardKey.digit1: '1',
    LogicalKeyboardKey.digit2: '2',
    LogicalKeyboardKey.digit3: '3',
    LogicalKeyboardKey.digit4: '4',
    LogicalKeyboardKey.digit5: '5',
    LogicalKeyboardKey.digit6: '6',
    LogicalKeyboardKey.digit7: '7',
    LogicalKeyboardKey.digit8: '8',
    LogicalKeyboardKey.digit9: '9',
    LogicalKeyboardKey.numpad0: '0',
    LogicalKeyboardKey.numpad1: '1',
    LogicalKeyboardKey.numpad2: '2',
    LogicalKeyboardKey.numpad3: '3',
    LogicalKeyboardKey.numpad4: '4',
    LogicalKeyboardKey.numpad5: '5',
    LogicalKeyboardKey.numpad6: '6',
    LogicalKeyboardKey.numpad7: '7',
    LogicalKeyboardKey.numpad8: '8',
    LogicalKeyboardKey.numpad9: '9',
  };

  static String? _digitFor(LogicalKeyboardKey key) => _digits[key];

  String get _title => widget.unlocking
      ? widget.profileName
      : _firstEntry == null
      ? 'Set a PIN'
      : 'Confirm the PIN';

  String get _message {
    if (_unreadable) {
      return 'This profile’s PIN was set by a newer version of the app. '
          'Update to open it.';
    }
    if (_cooling) return 'Too many attempts. Try again in $_secondsLeft s.';
    if (widget.unlocking) return 'Enter the PIN for this profile.';
    return _firstEntry == null
        ? 'Choose a $kProfilePinLength-digit PIN for '
              '“${widget.profileName}”.'
        : 'Enter it once more to confirm.';
  }

  @override
  Widget build(BuildContext context) {
    // Two different questions. `keypad` is "does this platform type or tap?",
    // which decides who holds focus; `padDrawn` is "is there actually a pad on
    // screen?", which an unreadable verifier turns off.
    final keypad = pinKeypadForPlatform(defaultTargetPlatform);
    final padDrawn = keypad && !_unreadable;
    // **The pad must fit the window, not scroll inside it.** This dialog is
    // modal on a screen the user cannot leave without typing four digits, and
    // the keys are the only way to type them on a remote — a key below the fold
    // is a profile that cannot be opened, and "scroll down" is not something a
    // D-pad does inside a dialog. So the lattice is laid out at its comfortable
    // size and *scaled down* to whatever is left (below), and the explanatory
    // line — the one piece of chrome that is nice rather than necessary — is
    // dropped on a short viewport so the pad keeps that space instead. A
    // landscape handset at a 2.0 text scale is the case that forces both.
    final short = MediaQuery.sizeOf(context).height < 420;
    return AlertDialog(
      backgroundColor: AppColors.panel,
      insetPadding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: short ? 8 : 24,
      ),
      titlePadding: EdgeInsets.fromLTRB(24, short ? 12 : 20, 24, 0),
      contentPadding: EdgeInsets.fromLTRB(24, short ? 8 : 16, 24, 0),
      title: Text(_title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Focus(
        // Holds focus itself only when there is no pad to hold it: with a pad,
        // this node stays in the chain purely to catch digits bubbling up from
        // the focused button.
        canRequestFocus: !keypad,
        autofocus: !keypad,
        onKeyEvent: _onKey,
        child: SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!short) ...[
                Text(
                  _message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: _cooling || _unreadable
                        ? AppColors.warning
                        : AppColors.textLo,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _PinDots(
                filled: _entry.length,
                error: _error != null,
                dimmed: _cooling || _unreadable,
              ),
              // On a short viewport the message is gone, so the two states it
              // would have explained have to say themselves somewhere.
              if (short && (_cooling || _unreadable)) ...[
                const SizedBox(height: 8),
                Text(
                  _message,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.warning,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.danger,
                  ),
                ),
              ],
              if (!_unreadable) ...[
                SizedBox(height: short ? 8 : 16),
                if (padDrawn)
                  // `Flexible` + `scaleDown`: the pad takes whatever height is
                  // left after the lines above and shrinks uniformly to fit it,
                  // rather than overflowing or being pushed off screen. It only
                  // ever scales *down*, so nothing changes on a roomy layout.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _Keypad(
                        enabled: !_cooling,
                        onDigit: _append,
                        onBackspace: _backspace,
                      ),
                    ),
                  )
                else
                  const Text(
                    'Type the digits on your keyboard.',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: AppColors.textLo),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          // Focus has exactly one home, and it is not shared. On a keypad
          // platform the D-pad should land on a digit, so Cancel takes focus
          // only when there is no pad to land on. On desktop it must *never*
          // take it: Cancel lives in `actions`, a sibling of `content`, so a
          // digit typed while it holds focus would never reach the handler
          // above — the dialog would silently stop accepting the keyboard,
          // which is the only input it has there.
          autofocus: keypad && !padDrawn,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PinDots extends StatelessWidget {
  final int filled;
  final bool error;
  final bool dimmed;

  const _PinDots({
    required this.filled,
    required this.error,
    required this.dimmed,
  });

  @override
  Widget build(BuildContext context) {
    final active = error
        ? AppColors.danger
        : dimmed
        ? AppColors.textLo
        : AppColors.accent;
    return Semantics(
      // The count, never the digits: this label is read aloud.
      label: '$filled of $kProfilePinLength digits entered',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < kProfilePinLength; i++)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 6),
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < filled ? active : Colors.transparent,
                border: Border.all(
                  color: i < filled ? active : AppColors.line,
                  width: 2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  final bool enabled;
  final void Function(String digit) onDigit;
  final VoidCallback onBackspace;

  const _Keypad({
    required this.enabled,
    required this.onDigit,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, Widget? child}) => SizedBox(
      width: 68,
      height: 52,
      child: FocusableCard(
        // The pad is a fixed lattice inside a dialog — there is no viewport to
        // scroll a focused key into.
        scrollOnFocus: false,
        autofocus: label == '1',
        semanticsLabel: label,
        onTap: enabled ? (onTap ?? () => onDigit(label)) : () {},
        child: Center(
          child:
              child ??
              Text(
                label,
                // The digit deliberately ignores the platform text scale. The
                // pad is scaled as a whole to fit the window, so scaling the
                // glyph inside a fixed key would only overflow the key — and a
                // numeral on a key whose size is already set by the lattice is
                // the one label where the size is a layout fact rather than a
                // legibility preference.
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: enabled ? AppColors.textHi : AppColors.textLo,
                ),
              ),
        ),
      ),
    );

    Widget row(List<Widget> children) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          children[i],
        ],
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([key('1'), key('2'), key('3')]),
        row([key('4'), key('5'), key('6')]),
        row([key('7'), key('8'), key('9')]),
        row([
          const SizedBox(width: 68, height: 52),
          key('0'),
          key(
            'Delete',
            onTap: onBackspace,
            child: Icon(
              Icons.backspace_outlined,
              size: 20,
              color: enabled ? AppColors.textHi : AppColors.textLo,
            ),
          ),
        ]),
      ],
    );
  }
}
