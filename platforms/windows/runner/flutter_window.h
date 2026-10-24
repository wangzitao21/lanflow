#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <shellapi.h>

#include "win32_window.h"

class FilePickerChannel;
class AsyncClipboard;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> clipboard_channel_;
  std::unique_ptr<AsyncClipboard> clipboard_reader_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_channel_;
  std::unique_ptr<FilePickerChannel> file_picker_channel_;
  NOTIFYICONDATAW tray_{};
  bool force_quit_ = false;
  bool quit_requested_ = false;
  bool tray_registered_ = false;
  bool first_frame_ = false;
  bool dark_mode_ = false;
  bool english_ = false;
  bool sync_paused_ = false;
  bool persist_placement_ = false;
  ULONGLONG created_at_ = 0;
  ULONGLONG engine_ready_ms_ = 0;
  ULONGLONG plugins_ready_ms_ = 0;
  ULONGLONG first_frame_ms_ = 0;
  bool InitializeFlutter();
  void SetDarkMode(bool dark, bool persist);
  void SetLanguage(bool english, bool persist);
  void UpdateTrayTooltip();
  void AddTray();
  void Restore();
  void RequestQuit(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> reply = nullptr);
  int LoadPlacement();
  void SavePlacement();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
