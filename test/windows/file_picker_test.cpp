#include "../../platforms/windows/runner/file_picker_bridge.h"

#include <objbase.h>

#include <atomic>
#include <functional>
#include <iostream>
#include <mutex>
#include <stdexcept>

namespace {
constexpr UINT kHeartbeat = WM_APP + 81;
constexpr HRESULT kCancelled = HRESULT_FROM_WIN32(ERROR_CANCELLED);

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

struct Gate {
  HANDLE factory_entered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE factory_release = CreateEventW(nullptr, TRUE, TRUE, nullptr);
  HANDLE show_entered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE show_release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE destroyed = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::atomic<DWORD> factory_thread{0}, show_thread{0}, cancel_thread{0};
  std::atomic<bool> sta{false}, cancelled{false}, throw_factory{false};
  std::atomic<int> creations{0};
  std::mutex mutex;
  lanflow::FilePickerOptions options;
  HWND owner = nullptr;
  ~Gate() {
    for (const auto event : {factory_entered, factory_release, show_entered, show_release, destroyed}) CloseHandle(event);
  }
};

class ControlledDialog final : public lanflow::FilePickerDialog {
 public:
  explicit ControlledDialog(std::shared_ptr<Gate> gate) : gate_(std::move(gate)) {}
  ~ControlledDialog() override { SetEvent(gate_->destroyed); }

  lanflow::FilePickerResult Show(HWND owner, const lanflow::FilePickerOptions& options,
                                 const std::atomic<bool>&) override {
    gate_->show_thread.store(GetCurrentThreadId());
    {
      std::lock_guard<std::mutex> lock(gate_->mutex);
      gate_->options = options;
      gate_->owner = owner;
    }
    SetEvent(gate_->show_entered);
    // Like IFileDialog::Show, this controlled modal operation pumps its STA.
    // Main-thread responsiveness is measured independently by the host below.
    while (!gate_->cancelled.load()) {
      const DWORD status = MsgWaitForMultipleObjects(1, &gate_->show_release,
          FALSE, 5000, QS_ALLINPUT);
      if (status == WAIT_OBJECT_0) break;
      if (status != WAIT_OBJECT_0 + 1) return {E_ABORT, {}};
      MSG message;
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
    }
    if (gate_->cancelled.load()) return {kCancelled, {}};
    return {S_OK, {L"C:\\test\\图片 空格.png", L"C:\\test\\second.txt"}};
  }

  void Cancel() override {
    gate_->cancel_thread.store(GetCurrentThreadId());
    gate_->cancelled.store(true);
  }

 private:
  std::shared_ptr<Gate> gate_;
};

lanflow::AsyncFilePicker::Factory Factory(std::shared_ptr<Gate> gate) {
  return [gate] {
    gate->creations.fetch_add(1);
    gate->factory_thread.store(GetCurrentThreadId());
    APTTYPE apartment;
    APTTYPEQUALIFIER qualifier;
    gate->sta.store(SUCCEEDED(CoGetApartmentType(&apartment, &qualifier)) &&
        (apartment == APTTYPE_STA || apartment == APTTYPE_MAINSTA));
    SetEvent(gate->factory_entered);
    Require(WaitForSingleObject(gate->factory_release, 5000) == WAIT_OBJECT_0,
        "The controlled shell creation was not released");
    if (gate->throw_factory.load()) throw std::runtime_error("Controlled shell failure");
    return std::make_unique<ControlledDialog>(gate);
  };
}

struct Host {
  HWND window = nullptr;
  std::unique_ptr<lanflow::AsyncFilePicker> picker;
  int heartbeats = 0;
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto creation = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(creation->lpCreateParams));
    }
    const auto self = reinterpret_cast<Host*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self) {
      if (message == kHeartbeat || message == WM_TIMER) { ++self->heartbeats; return 0; }
      if (self->picker && self->picker->HandleMessage(message, wparam)) return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }
  explicit Host(std::shared_ptr<Gate> gate) {
    static bool registered = false;
    if (!registered) {
      WNDCLASSW definition{};
      definition.hInstance = GetModuleHandleW(nullptr);
      definition.lpszClassName = L"LANFLOW_PICKER_TEST_HOST";
      definition.lpfnWndProc = WindowProc;
      Require(RegisterClassW(&definition) != 0, "Cannot register test host");
      registered = true;
    }
    window = CreateWindowExW(0, L"LANFLOW_PICKER_TEST_HOST", L"", WS_OVERLAPPED,
        0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), this);
    Require(window != nullptr, "Cannot create hidden test host");
    picker = std::make_unique<lanflow::AsyncFilePicker>(window, Factory(gate));
  }
  ~Host() {
    picker.reset();
    if (window) DestroyWindow(window);
  }
  void Until(const std::function<bool()>& ready) {
    const ULONGLONG deadline = GetTickCount64() + 5000;
    while (!ready()) {
      Require(GetTickCount64() < deadline, "Timed out while pumping the UI thread");
      MSG message;
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
      MsgWaitForMultipleObjects(0, nullptr, FALSE, 5, QS_ALLINPUT);
    }
  }
};

bool Signalled(HANDLE event) { return WaitForSingleObject(event, 0) == WAIT_OBJECT_0; }

void SlowShellDoesNotOccupyPlatformThread() {
  const DWORD platform = GetCurrentThreadId();
  auto gate = std::make_shared<Gate>();
  ResetEvent(gate->factory_release);
  Host host(gate);
  int replies = 0, duplicate_replies = 0;
  DWORD reply_thread = 0;
  lanflow::FilePickerResult received;
  lanflow::FilePickerOptions options;
  options.multiple = true;
  options.initial_directory = L"C:\\test\\pictures";
  options.confirm_label = L"选择";
  options.filters = {{L"Images", {L"png", L"jpg"}}};
  Require(host.picker->Open(options, [&](auto result) {
    ++replies; reply_thread = GetCurrentThreadId(); received = std::move(result);
  }), "First picker request was rejected");
  host.Until([&] { return Signalled(gate->factory_entered); });
  Require(!host.picker->Open({}, [&](auto) { ++duplicate_replies; }), "Duplicate picker opened concurrently");
  SetTimer(host.window, 1, 10, nullptr);
  PostMessageW(host.window, kHeartbeat, 0, 0);
  host.Until([&] { return host.heartbeats >= 5; });
  KillTimer(host.window, 1);
  Require(replies == 0 && !Signalled(gate->show_entered), "Controlled initialization did not remain pending");
  Require(gate->factory_thread.load() != platform && gate->sta.load(), "Shell work did not run on an independent STA");
  SetEvent(gate->factory_release);
  host.Until([&] { return Signalled(gate->show_entered); });
  {
    std::lock_guard<std::mutex> lock(gate->mutex);
    Require(gate->options.multiple && gate->options.filters[0].extensions.size() == 2 &&
        gate->options.confirm_label == L"选择" && gate->owner == host.window,
        "Selection options or native ownership changed across threads");
  }
  SetEvent(gate->show_release);
  host.Until([&] { return replies == 1; });
  Require(reply_thread == platform, "Result was not delivered on the platform thread");
  Require(received.status == S_OK && received.paths.size() == 2 &&
      received.paths[0] == L"C:\\test\\图片 空格.png", "Selected Unicode paths were lost");
  Require(duplicate_replies == 0 && !host.picker->busy(), "Duplicate result or stuck busy state");
  std::cout << "Independent STA initialization allowed " << host.heartbeats
            << " UI messages/timers before release; selection returned on UI thread\n";
}

void CancelAndReopen() {
  auto gate = std::make_shared<Gate>();
  Host host(gate);
  int replies = 0;
  lanflow::FilePickerResult received;
  Require(host.picker->Open({}, [&](auto result) { ++replies; received = std::move(result); }), "Cannot open cancel test");
  host.Until([&] { return Signalled(gate->show_entered); });
  host.picker->Cancel();
  Require(!host.picker->Open({}, [](auto) {}), "A cancelling picker allowed a second modal dialog");
  host.Until([&] { return replies == 1; });
  Require(received.status == kCancelled && received.paths.empty(), "Cancel returned selected files");
  Require(gate->cancel_thread.load() == gate->show_thread.load() &&
      gate->cancel_thread.load() != GetCurrentThreadId(), "Cancel crossed the COM apartment boundary");
  gate->cancelled.store(false);
  ResetEvent(gate->show_entered);
  ResetEvent(gate->destroyed);
  SetEvent(gate->show_release);
  Require(host.picker->Open({}, [&](auto result) { ++replies; received = std::move(result); }), "Picker could not reopen after cancellation");
  host.Until([&] { return replies == 2; });
  Require(received.status == S_OK && received.paths.size() == 2, "Reopened picker returned a stale cancellation");
}

void CancelQueuedSelectionBeforeQuit() {
  auto gate = std::make_shared<Gate>();
  Host host(gate);
  int replies = 0;
  lanflow::FilePickerResult received;
  SetEvent(gate->show_release);
  Require(host.picker->Open({}, [&](auto result) { ++replies; received = std::move(result); }), "Cannot open quit race test");
  const auto deadline = GetTickCount64() + 5000;
  MSG pending;
  // Deliberately leave the completion queued, as a tray Quit can be dispatched
  // before Flutter receives a completed file selection.
  while (!PeekMessageW(&pending, host.window, lanflow::AsyncFilePicker::kCompletedMessage,
      lanflow::AsyncFilePicker::kCompletedMessage, PM_NOREMOVE)) {
    Require(GetTickCount64() < deadline, "Worker did not queue a result");
    Sleep(1);
  }
  host.picker->Cancel();
  host.Until([&] { return replies == 1; });
  Require(received.status == kCancelled && received.paths.empty(), "A queued selection survived quit cancellation");
}

void DestructionDoesNotWaitOrReplyIntoDeadEngine() {
  auto gate = std::make_shared<Gate>();
  ResetEvent(gate->factory_release);
  Host host(gate);
  int replies = 0;
  Require(host.picker->Open({}, [&](auto) { ++replies; }), "Cannot open destruction test");
  host.Until([&] { return Signalled(gate->factory_entered); });
  const auto before = GetTickCount64();
  host.picker.reset();
  Require(GetTickCount64() - before < 500, "Destruction waited for blocked shell initialization");
  Require(!Signalled(gate->factory_release), "The worker was not actually blocked");
  DestroyWindow(host.window);
  host.window = nullptr;
  SetEvent(gate->factory_release);
  host.Until([&] { return Signalled(gate->destroyed); });
  Require(replies == 0 && !Signalled(gate->show_entered), "A destroyed owner opened a dialog or received a late reply");
}

void ShellFailureDoesNotLeavePickerBusy() {
  auto gate = std::make_shared<Gate>();
  gate->throw_factory.store(true);
  Host host(gate);
  int replies = 0;
  HRESULT status = S_OK;
  Require(host.picker->Open({}, [&](auto result) { ++replies; status = result.status; }), "Cannot open failure test");
  host.Until([&] { return replies == 1; });
  Require(FAILED(status) && !host.picker->busy(), "Shell failure did not clear pending state");
  gate->throw_factory.store(false);
  SetEvent(gate->show_release);
  Require(host.picker->Open({}, [&](auto result) { ++replies; status = result.status; }), "Cannot retry after shell failure");
  host.Until([&] { return replies == 2; });
  Require(status == S_OK, "Retry still used the failed request");
}
}  // namespace

int main() {
  try {
    SlowShellDoesNotOccupyPlatformThread();
    CancelAndReopen();
    CancelQueuedSelectionBeforeQuit();
    DestructionDoesNotWaitOrReplyIntoDeadEngine();
    ShellFailureDoesNotLeavePickerBusy();
    std::cout << "Picker STA, UI response, Unicode result, cancellation, reopen and shutdown checks passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
