#ifndef RUNNER_CLIPBOARD_BRIDGE_H_
#define RUNNER_CLIPBOARD_BRIDGE_H_
#include <windows.h>
#include <optional>
#include <vector>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

struct ClipboardSnapshot {
  std::vector<uint8_t> png;
  std::shared_ptr<void> bitmap;
};

struct ClipboardResult {
  std::optional<std::vector<uint8_t>> png;
  std::string error;
};

std::vector<uint8_t> BitmapToPng(HBITMAP bitmap);
ClipboardSnapshot SnapshotBitmap(HBITMAP bitmap);
std::optional<ClipboardSnapshot> ReadClipboardSnapshot(HWND window);
std::optional<std::vector<uint8_t>> EncodeClipboardSnapshot(std::optional<ClipboardSnapshot> snapshot);
std::optional<std::vector<uint8_t>> ReadClipboardPng(HWND window);

// Snapshot ownership crosses the worker boundary; Flutter callbacks never do.
class AsyncClipboard {
 public:
  static constexpr UINT kCompletedMessage = WM_APP + 5;
  using Encoder = std::function<std::optional<std::vector<uint8_t>>(std::optional<ClipboardSnapshot>)>;
  using Completion = std::function<void(ClipboardResult)>;
  explicit AsyncClipboard(HWND owner, Encoder encoder = EncodeClipboardSnapshot);
  ~AsyncClipboard();
  bool Encode(std::optional<ClipboardSnapshot> snapshot, Completion completion);
  bool HandleMessage(UINT message, WPARAM token);
  void Shutdown();
 private:
  struct State;
  std::shared_ptr<State> state_;
  Completion completion_;
  DWORD platform_thread_;
  static void Run(std::shared_ptr<State> state, std::uint64_t token, std::optional<ClipboardSnapshot> snapshot);
};
#endif
