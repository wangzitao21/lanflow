#include "file_picker_bridge.h"

#include <shobjidl.h>
#include <wrl/client.h>

#include <mutex>
#include <optional>
#include <thread>
#include <utility>

namespace lanflow {
namespace {
using Microsoft::WRL::ComPtr;
constexpr UINT kCancelMessage = WM_APP + 41;
constexpr wchar_t kControlClass[] = L"LANFLOW_FILE_PICKER_CONTROL";
constexpr HRESULT kCancelled = HRESULT_FROM_WIN32(ERROR_CANCELLED);

class ShellFilePicker final : public FilePickerDialog {
 public:
  FilePickerResult Show(HWND owner, const FilePickerOptions& options,
                        const std::atomic<bool>& cancelled) override {
    FilePickerResult result;
    result.status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog_));
    if (FAILED(result.status)) return result;
    FILEOPENDIALOGOPTIONS flags = 0;
    result.status = dialog_->GetOptions(&flags);
    if (FAILED(result.status)) return result;
    flags |= FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST |
        FOS_NOCHANGEDIR;
    if (options.multiple) flags |= FOS_ALLOWMULTISELECT;
    result.status = dialog_->SetOptions(flags);
    if (FAILED(result.status)) return result;

    std::vector<std::wstring> labels;
    std::vector<std::wstring> patterns;
    std::vector<COMDLG_FILTERSPEC> filters;
    labels.reserve(options.filters.size());
    patterns.reserve(options.filters.size());
    filters.reserve(options.filters.size());
    for (const auto& filter : options.filters) {
      labels.push_back(filter.label);
      std::wstring pattern;
      for (const auto& extension : filter.extensions) {
        if (!pattern.empty()) pattern += L';';
        pattern += L"*." + extension;
      }
      patterns.push_back(pattern.empty() ? L"*.*" : std::move(pattern));
      filters.push_back({labels.back().c_str(), patterns.back().c_str()});
    }
    if (!filters.empty()) {
      result.status = dialog_->SetFileTypes(static_cast<UINT>(filters.size()), filters.data());
      if (FAILED(result.status)) return result;
    }
    if (!options.confirm_label.empty()) {
      result.status = dialog_->SetOkButtonLabel(options.confirm_label.c_str());
      if (FAILED(result.status)) return result;
    }
    if (!options.initial_directory.empty()) {
      ComPtr<IShellItem> directory;
      // Resolving a disconnected network folder can be slow; it belongs on
      // this STA too. An unavailable initial folder keeps the shell's default.
      if (SUCCEEDED(SHCreateItemFromParsingName(options.initial_directory.c_str(),
          nullptr, IID_PPV_ARGS(&directory)))) {
        dialog_->SetFolder(directory.Get());
      }
    }
    if (cancelled.load()) { result.status = kCancelled; return result; }
    if (!IsWindow(owner)) { result.status = kCancelled; return result; }
    result.status = dialog_->Show(owner);
    if (FAILED(result.status) || cancelled.load()) {
      if (cancelled.load()) result.status = kCancelled;
      return result;
    }
    ComPtr<IShellItemArray> selected;
    result.status = dialog_->GetResults(&selected);
    if (FAILED(result.status)) return result;
    DWORD count = 0;
    result.status = selected->GetCount(&count);
    if (FAILED(result.status)) return result;
    result.paths.reserve(count);
    for (DWORD index = 0; index < count; ++index) {
      ComPtr<IShellItem> item;
      result.status = selected->GetItemAt(index, &item);
      if (FAILED(result.status)) break;
      PWSTR path = nullptr;
      result.status = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
      if (FAILED(result.status)) break;
      const std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owned(path, &CoTaskMemFree);
      result.paths.emplace_back(owned.get());
    }
    if (FAILED(result.status)) result.paths.clear();
    return result;
  }

  void Cancel() override {
    if (dialog_) dialog_->Close(kCancelled);
  }

 private:
  ComPtr<IFileOpenDialog> dialog_;
};
}  // namespace

struct AsyncFilePicker::State {
  mutable std::mutex mutex;
  HWND owner = nullptr;
  HWND control = nullptr;
  Factory factory;
  std::atomic<bool> cancelled{false};
  bool shutdown = false;
  bool active = false;
  std::uint64_t token = 0;
  std::optional<FilePickerResult> completed;
};

struct AsyncFilePicker::WorkerContext {
  State* state;
  FilePickerDialog* dialog = nullptr;
};

AsyncFilePicker::AsyncFilePicker(HWND owner, Factory factory)
    : state_(std::make_shared<State>()), platform_thread_(GetCurrentThreadId()) {
  state_->owner = owner;
  state_->factory = factory ? std::move(factory)
      : Factory([] { return std::make_unique<ShellFilePicker>(); });
}

AsyncFilePicker::~AsyncFilePicker() { Shutdown(); }

bool AsyncFilePicker::Open(FilePickerOptions options, Completion completion) {
  if (GetCurrentThreadId() != platform_thread_) return false;
  std::uint64_t token;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->shutdown || state_->active) return false;
    state_->active = true;
    state_->cancelled.store(false);
    state_->completed.reset();
    token = ++state_->token;
  }
  completion_ = std::move(completion);
  try {
    // Only shared state crosses the thread boundary, never this object, a
    // Flutter channel, or a MethodResult that may outlive the engine.
    std::thread(&AsyncFilePicker::Run, state_, token, std::move(options)).detach();
  } catch (...) {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->completed = FilePickerResult{E_FAIL, {}};
    }
    HandleMessage(kCompletedMessage, static_cast<WPARAM>(token));
  }
  return true;
}

void AsyncFilePicker::Cancel() {
  HWND control;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->active) return;
    state_->cancelled.store(true);
    control = state_->control;
  }
  if (control) PostMessageW(control, kCancelMessage, 0, 0);
}

bool AsyncFilePicker::HandleMessage(UINT message, WPARAM token) {
  if (message != kCompletedMessage || GetCurrentThreadId() != platform_thread_) return false;
  std::optional<FilePickerResult> result;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->shutdown || state_->token != token || !state_->completed) return true;
    result = std::move(state_->completed);
    state_->completed.reset();
    state_->active = false;
    if (state_->cancelled.load()) result = FilePickerResult{kCancelled, {}};
  }
  auto callback = std::move(completion_);
  completion_ = nullptr;
  if (callback) callback(std::move(*result));
  return true;
}

void AsyncFilePicker::Shutdown() {
  HWND control;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->shutdown = true;
    state_->cancelled.store(true);
    state_->owner = nullptr;
    state_->completed.reset();
    control = state_->control;
  }
  completion_ = nullptr;
  if (control) PostMessageW(control, kCancelMessage, 0, 0);
}

bool AsyncFilePicker::busy() const {
  std::lock_guard<std::mutex> lock(state_->mutex);
  return !state_->shutdown && state_->active;
}

LRESULT CALLBACK AsyncFilePicker::ControlWindowProc(HWND window, UINT message,
                                                   WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto creation = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(creation->lpCreateParams));
  }
  const auto context = reinterpret_cast<WorkerContext*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == kCancelMessage && context) {
    context->state->cancelled.store(true);
    // The modal shell loop dispatches this on its own STA, not the caller.
    if (context->dialog) {
      try { context->dialog->Cancel(); } catch (...) { /* Cancellation is still recorded. */ }
    }
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void AsyncFilePicker::Run(std::shared_ptr<State> state, std::uint64_t token,
                          FilePickerOptions options) {
  FilePickerResult result;
  const HRESULT initialized = CoInitializeEx(nullptr,
      COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  if (FAILED(initialized)) {
    result.status = initialized;
  } else {
    HWND control = nullptr;
    WorkerContext context{state.get()};
    try {
      static std::once_flag registered;
      static ATOM window_class = 0;
      std::call_once(registered, [] {
        WNDCLASSW definition{};
        definition.hInstance = GetModuleHandleW(nullptr);
        definition.lpszClassName = kControlClass;
        definition.lpfnWndProc = &AsyncFilePicker::ControlWindowProc;
        window_class = RegisterClassW(&definition);
      });
      if (window_class) {
        control = CreateWindowExW(0, kControlClass, L"", 0, 0, 0, 0, 0,
            HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), &context);
      }
      if (!control) {
        result.status = HRESULT_FROM_WIN32(GetLastError());
        if (SUCCEEDED(result.status)) result.status = E_FAIL;
      } else {
        HWND owner;
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          state->control = control;
          owner = state->owner;
        }
        auto dialog = state->factory();
        context.dialog = dialog.get();
        if (!dialog) {
          result.status = E_FAIL;
        } else if (state->cancelled.load()) {
          result.status = kCancelled;
        } else {
          result = dialog->Show(owner, options, state->cancelled);
        }
        context.dialog = nullptr;
      }
    } catch (...) {
      context.dialog = nullptr;
      result.status = E_FAIL;
      result.paths.clear();
    }
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->control = nullptr;
    }
    if (control) DestroyWindow(control);
    CoUninitialize();
  }
  HWND owner;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->shutdown || state->token != token) return;
    state->completed = std::move(result);
    owner = state->owner;
  }
  if (owner && !PostMessageW(owner, kCompletedMessage, static_cast<WPARAM>(token), 0)) {
    // Still asynchronous for another thread; no Flutter calls from this STA.
    SendNotifyMessageW(owner, kCompletedMessage, static_cast<WPARAM>(token), 0);
  }
}

}  // namespace lanflow
