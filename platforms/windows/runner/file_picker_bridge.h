#ifndef RUNNER_FILE_PICKER_BRIDGE_H_
#define RUNNER_FILE_PICKER_BRIDGE_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace lanflow {

struct FilePickerFilter {
  std::wstring label;
  std::vector<std::wstring> extensions;
};

struct FilePickerOptions {
  bool multiple = true;
  std::wstring initial_directory;
  std::wstring confirm_label;
  std::vector<FilePickerFilter> filters;
};

struct FilePickerResult {
  HRESULT status = S_OK;
  std::vector<std::wstring> paths;
};

// All backend methods, including construction and destruction, run on the same
// independent STA. Tests can substitute a modal implementation without opening
// a visible system dialog or accessing the user's files.
class FilePickerDialog {
 public:
  virtual ~FilePickerDialog() = default;
  virtual FilePickerResult Show(HWND owner, const FilePickerOptions& options,
                                const std::atomic<bool>& cancelled) = 0;
  virtual void Cancel() = 0;
};

class AsyncFilePicker {
 public:
  static constexpr UINT kCompletedMessage = WM_APP + 4;
  using Factory = std::function<std::unique_ptr<FilePickerDialog>()>;
  using Completion = std::function<void(FilePickerResult)>;

  explicit AsyncFilePicker(HWND owner, Factory factory = {});
  ~AsyncFilePicker();
  AsyncFilePicker(const AsyncFilePicker&) = delete;
  AsyncFilePicker& operator=(const AsyncFilePicker&) = delete;

  // Called by the platform thread. False means another request is still active.
  // No shell/COM initialization, directory lookup, or dialog wait occurs here.
  bool Open(FilePickerOptions options, Completion completion);
  void Cancel();
  bool HandleMessage(UINT message, WPARAM token);
  // Does not wait for a slow shell extension and never calls back after return.
  void Shutdown();
  bool busy() const;

 private:
  struct State;
  struct WorkerContext;
  std::shared_ptr<State> state_;
  Completion completion_;
  DWORD platform_thread_;
  static LRESULT CALLBACK ControlWindowProc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam);
  static void Run(std::shared_ptr<State> state, std::uint64_t token,
                  FilePickerOptions options);
};

}  // namespace lanflow

#endif  // RUNNER_FILE_PICKER_BRIDGE_H_
