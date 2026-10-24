import 'dart:async';

/// Samples display-only progress. Transport, completion and new-message
/// notifications run independently and must never wait for this timer.
class SyncProgress {
  SyncProgress(this.sample);
  final void Function() sample;
  Timer? _timer;
  bool _running = false;
  bool _foreground = true;

  void start() {
    if (_running) return;
    _running = true;
    _schedule();
  }

  void setForeground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    if (!_running) return;
    if (value) sample();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(
      _foreground
          ? const Duration(milliseconds: 350)
          : const Duration(seconds: 3),
      (_) => sample(),
    );
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }
}
