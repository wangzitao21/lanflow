#include "flutter_window.h"

#include <optional>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include "clipboard_bridge.h"
#include "file_picker_channel.h"
#include "resource.h"
#include <shlobj.h>
#include <dwmapi.h>
#include "utils.h"
#include "window_geometry.h"
#include <flutter_windows.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {
struct SavedPlacement {
  DWORD version = 1;
  RECT bounds{};
  DWORD maximized = 0;
};
}

int FlutterWindow::LoadPlacement() {
  persist_placement_ = GetEnvironmentVariableW(L"LANFLOW_DATA_DIR", nullptr, 0) == 0;
  if (!persist_placement_) return SW_SHOWNORMAL;
  SavedPlacement saved;
  DWORD bytes = sizeof(saved);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\LanFlow", L"WindowPlacement",
      RRF_RT_REG_BINARY, nullptr, &saved, &bytes) != ERROR_SUCCESS ||
      bytes != sizeof(saved) || saved.version != 1 ||
      saved.bounds.right <= saved.bounds.left || saved.bounds.bottom <= saved.bounds.top) {
    return SW_SHOWNORMAL;
  }
  HMONITOR monitor = MonitorFromRect(&saved.bounds, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{sizeof(info)};
  if (!GetMonitorInfoW(monitor, &info)) return SW_SHOWNORMAL;
  const RECT rect = FitWindowBounds(
      saved.bounds, info.rcWork, FlutterDesktopGetDpiForMonitor(monitor));
  SetWindowPos(GetHandle(), nullptr, rect.left, rect.top,
      rect.right - rect.left, rect.bottom - rect.top, SWP_NOACTIVATE | SWP_NOZORDER);
  return saved.maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
}

void FlutterWindow::SavePlacement() {
  if (!persist_placement_ || !IsWindow(GetHandle())) return;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(GetHandle(), &placement) || IsIconic(GetHandle())) return;
  MONITORINFO info{sizeof(info)};
  if (!GetMonitorInfoW(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST), &info)) return;
  SavedPlacement saved;
  saved.bounds = placement.rcNormalPosition;
  // WINDOWPLACEMENT uses workspace coordinates for top-level app windows.
  OffsetRect(&saved.bounds, info.rcWork.left - info.rcMonitor.left,
      info.rcWork.top - info.rcMonitor.top);
  saved.maximized = placement.showCmd == SW_SHOWMAXIMIZED;
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\LanFlow", 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(key, L"WindowPlacement", 0, REG_BINARY,
        reinterpret_cast<const BYTE*>(&saved), sizeof(saved));
    RegCloseKey(key);
  }
}

void FlutterWindow::AddTray() {
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle();
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_.uCallbackMessage = WM_APP + 1;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  UpdateTrayTooltip();
  tray_registered_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
}

void FlutterWindow::UpdateTrayTooltip() {
  wcscpy_s(tray_.szTip, sync_paused_
      ? (english_ ? L"LanFlow · Sync paused" : L"LanFlow · 同步已暂停")
      : (english_ ? L"LanFlow · Saved messages" : L"LanFlow · 发给自己"));
  if (tray_registered_) Shell_NotifyIconW(NIM_MODIFY, &tray_);
}

void FlutterWindow::SetLanguage(bool english, bool persist) {
  english_ = english;
  if (persist && GetEnvironmentVariableW(L"LANFLOW_DATA_DIR", nullptr, 0) == 0) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\LanFlow", 0, nullptr, 0,
        KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
      DWORD value = english ? 1 : 0;
      RegSetValueExW(key, L"English", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
      RegCloseKey(key);
    }
  }
  UpdateTrayTooltip();
}

void FlutterWindow::Restore() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
  if (flutter_controller_) SetFocus(flutter_controller_->view()->GetNativeWindow());
}

void FlutterWindow::RequestQuit(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (quit_requested_) {
    if (result) result->Error("BUSY", "Saving before exit is already in progress");
    return;
  }
  if (!desktop_channel_) {
    if (result) result->Error("NOT_READY", "The application is still starting");
    return;
  }
  // A selection already queued for delivery must not begin importing files
  // after the Dart session has started its final save.
  if (file_picker_channel_) file_picker_channel_->Cancel();
  quit_requested_ = true;
  auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
  auto failed = [this, reply]() {
    quit_requested_ = false;
    const char* message = english_
        ? "Saving before exit did not finish. Your edits are kept in the application; check disk space and permissions, then try again."
        : u8"退出前保存未完成。编辑内容仍保留在应用中，请检查磁盘空间和权限后重试。";
    if (reply) {
      reply->Error("SAVE_FAILED", message);
    } else {
      Restore();
      MessageBoxW(GetHandle(), english_
          ? L"Saving before exit did not finish. Your edits are kept in the application. Check disk space and permissions, then try Quit again."
          : L"退出前保存未完成，编辑内容仍保留在应用中。请检查磁盘空间和权限，然后重新选择退出。",
          L"LanFlow", MB_OK | MB_ICONERROR);
    }
  };
  desktop_channel_->InvokeMethod("prepareToQuit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [this, reply, failed](const flutter::EncodableValue* value) {
            const auto saved = value ? std::get_if<bool>(value) : nullptr;
            if (!saved || !*saved) { failed(); return; }
            if (reply) reply->Success();
            force_quit_ = true;
            PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          },
          [failed](const std::string&, const std::string&, const flutter::EncodableValue*) { failed(); },
          failed));
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  created_at_ = GetTickCount64();

  DWORD preference = 0, bytes = sizeof(preference);
  RegGetValueW(HKEY_CURRENT_USER, L"Software\\LanFlow", L"DarkMode",
               RRF_RT_REG_DWORD, nullptr, &preference, &bytes);
  SetDarkMode(preference != 0, false);
  preference = 0;
  bytes = sizeof(preference);
  RegGetValueW(HKEY_CURRENT_USER, L"Software\\LanFlow", L"English",
               RRF_RT_REG_DWORD, nullptr, &preference, &bytes);
  SetLanguage(preference != 0, false);
  const int show_command = LoadPlacement();
  wchar_t hidden[2];
  if (GetEnvironmentVariableW(L"LANFLOW_START_HIDDEN", hidden, 2) == 0) {
    ShowWindow(GetHandle(), show_command);
    UpdateWindow(GetHandle());
  }
  // Paint the native host before constructing the engine. Initialization runs
  // on the next message so the window exists independently of Flutter startup.
  PostMessage(GetHandle(), WM_APP + 3, 0, 0);
  return true;
}

void FlutterWindow::SetDarkMode(bool dark, bool persist) {
  dark_mode_ = dark;
  BOOL enabled = dark;
  DwmSetWindowAttribute(GetHandle(), DWMWA_USE_IMMERSIVE_DARK_MODE, &enabled, sizeof(enabled));
  if (persist && GetEnvironmentVariableW(L"LANFLOW_DATA_DIR", nullptr, 0) == 0) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\LanFlow", 0, nullptr, 0,
        KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
      DWORD value = dark ? 1 : 0;
      RegSetValueExW(key, L"DarkMode", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
      RegCloseKey(key);
    }
  }
  if (!first_frame_) InvalidateRect(GetHandle(), nullptr, FALSE);
}

bool FlutterWindow::InitializeFlutter() {
  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  engine_ready_ms_ = GetTickCount64() - created_at_;
  RegisterPlugins(flutter_controller_->engine());
  file_picker_channel_ = std::make_unique<FilePickerChannel>(
      GetHandle(), flutter_controller_->engine()->messenger());
  plugins_ready_ms_ = GetTickCount64() - created_at_;
  clipboard_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "lanflow/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  clipboard_reader_ = std::make_unique<AsyncClipboard>(GetHandle());
  clipboard_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "readImage") { result->NotImplemented(); return; }
    auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    try {
      auto snapshot = ReadClipboardSnapshot(GetHandle());
      if (!clipboard_reader_->Encode(std::move(snapshot), [reply](ClipboardResult converted) {
        if (!converted.error.empty()) reply->Error("CLIPBOARD", converted.error);
        else if (converted.png) reply->Success(flutter::EncodableValue(std::move(*converted.png)));
        else reply->Success();
      })) reply->Error("CLIPBOARD_BUSY", "An image is already being prepared");
    } catch (const std::exception& error) { reply->Error("CLIPBOARD", error.what()); }
  });
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "lanflow/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "startupTiming") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("engineReadyMs"), flutter::EncodableValue(static_cast<int64_t>(engine_ready_ms_))},
        {flutter::EncodableValue("pluginsReadyMs"), flutter::EncodableValue(static_cast<int64_t>(plugins_ready_ms_))},
        {flutter::EncodableValue("firstFlutterFrameMs"), flutter::EncodableValue(static_cast<int64_t>(first_frame_ms_))},
      }));
      return;
    }
    if (call.method_name() == "setDarkMode") {
      const auto dark = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!dark) { result->Error("ARGUMENT", "Missing appearance"); return; }
      SetDarkMode(*dark, true); result->Success(); return;
    }
    if (call.method_name() == "setLanguage") {
      const auto language = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!language) { result->Error("ARGUMENT", "Missing language"); return; }
      SetLanguage(*language == "en", true); result->Success(); return;
    }
    if (call.method_name() == "setSyncPaused") {
      const auto paused = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!paused) { result->Error("ARGUMENT", "Missing sync state"); return; }
      sync_paused_ = *paused;
      UpdateTrayTooltip(); result->Success(); return;
    }
    if (call.method_name() == "hideToTray") {
      SavePlacement();
      if (!tray_registered_) AddTray();
      ShowWindow(GetHandle(), tray_registered_ ? SW_HIDE : SW_MINIMIZE); result->Success(); return;
    }
    if (call.method_name() == "quit") {
      RequestQuit(std::move(result)); return;
    }
    const auto value = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (!value) { result->Error("ARGUMENT", "Missing path or URL"); return; }
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value->data(), static_cast<int>(value->size()), nullptr, 0);
    if (!size) { result->Error("ARGUMENT", "Invalid text"); return; }
    std::wstring text(size, 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value->data(), static_cast<int>(value->size()), text.data(), size);
    if (call.method_name() == "showInFolder") {
      PIDLIST_ABSOLUTE item = nullptr;
      HRESULT status = SHParseDisplayName(text.c_str(), nullptr, &item, 0, nullptr);
      if (SUCCEEDED(status)) { status = SHOpenFolderAndSelectItems(item, 0, nullptr, 0); CoTaskMemFree(item); }
      if (FAILED(status)) result->Error("EXPLORER", "Cannot locate file"); else result->Success();
    } else if (call.method_name() == "openFile") {
      const DWORD attributes = GetFileAttributesW(text.c_str());
      if (text.find(L'\0') != std::wstring::npos || attributes == INVALID_FILE_ATTRIBUTES ||
          (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        result->Error("FILE", "The selected file is unavailable"); return;
      }
      auto status = reinterpret_cast<INT_PTR>(ShellExecuteW(GetHandle(), L"open", text.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      if (status <= 32) result->Error("FILE", "Cannot open the selected file"); else result->Success();
    } else if (call.method_name() == "openUrl") {
      if (text.rfind(L"https://", 0) != 0 && text.rfind(L"http://", 0) != 0) { result->Error("URL", "Unsupported URL"); return; }
      auto status = reinterpret_cast<INT_PTR>(ShellExecuteW(GetHandle(), L"open", text.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      if (status <= 32) result->Error("URL", "Cannot open link"); else result->Success();
    } else result->NotImplemented();
  });
  AddTray();
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    first_frame_ms_ = GetTickCount64() - created_at_;
    first_frame_ = true;
    SetChildContent(flutter_controller_->view()->GetNativeWindow());
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Cancel/drop asynchronous picker replies before destroying their messenger.
  file_picker_channel_ = nullptr;
  if (tray_.hWnd) { Shell_NotifyIconW(NIM_DELETE, &tray_); tray_.hWnd = nullptr; }
  desktop_channel_ = nullptr;
  clipboard_reader_ = nullptr;
  clipboard_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (file_picker_channel_ && file_picker_channel_->HandleMessage(message, wparam)) return 0;
  if (clipboard_reader_ && clipboard_reader_->HandleMessage(message, wparam)) return 0;
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == WM_GETMINMAXINFO) {
    const UINT dpi = GetDpiForWindow(hwnd);
    auto limits = reinterpret_cast<MINMAXINFO*>(lparam);
    limits->ptMinTrackSize.x = MulDiv(880, dpi ? dpi : 96, 96);
    limits->ptMinTrackSize.y = MulDiv(560, dpi ? dpi : 96, 96);
    return 0;
  }
  if (message == WM_APP + 3) {
    if (!InitializeFlutter()) { force_quit_ = true; PostMessage(hwnd, WM_CLOSE, 0, 0); }
    return 0;
  }
  if (message == WM_PAINT && !first_frame_) {
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(hwnd, &paint);
    RECT area = GetClientArea();
    HBRUSH background = CreateSolidBrush(dark_mode_ ? RGB(25,30,28) : RGB(246,248,247));
    FillRect(dc, &area, background);
    DeleteObject(background);
    // A stable shell is visible while local history loads; no spinner or
    // entrance animation delays the first usable Flutter frame.
    const UINT dpi = GetDpiForWindow(hwnd);
    const int sidebar_width = MulDiv(314, dpi ? dpi : 96, 96);
    const int rail_width = MulDiv(64, dpi ? dpi : 96, 96);
    RECT sidebar = area;
    sidebar.right = std::min<LONG>(area.right, sidebar_width);
    HBRUSH panel = CreateSolidBrush(dark_mode_ ? RGB(32,40,35) : RGB(240,244,241));
    FillRect(dc, &sidebar, panel);
    DeleteObject(panel);
    sidebar.right = std::min<LONG>(area.right, rail_width);
    panel = CreateSolidBrush(dark_mode_ ? RGB(27,35,30) : RGB(232,239,235));
    FillRect(dc, &sidebar, panel);
    DeleteObject(panel);
    EndPaint(hwnd, &paint);
    return 0;
  }
  if (message == taskbar_created) { AddTray(); return 0; }
  if (message == WM_DWMCOLORIZATIONCOLORCHANGED) { SetDarkMode(dark_mode_, false); return 0; }
  if (message == WM_APP + 2) { Restore(); return 0; }
  if (message == WM_EXITSIZEMOVE) SavePlacement();
  if (message == WM_CLOSE) {
    SavePlacement();
    if (!force_quit_) {
      if (!tray_registered_) AddTray();
      ShowWindow(hwnd, tray_registered_ ? SW_HIDE : SW_MINIMIZE); return 0;
    }
  }
  if (message == WM_APP + 1) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) Restore();
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      POINT point; GetCursorPos(&point); HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, english_ ? L"Open LanFlow" : L"打开 LanFlow");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING | (quit_requested_ ? MF_GRAYED : 0), 2,
          quit_requested_ ? (english_ ? L"Saving before exit…" : L"正在保存并退出…") : (english_ ? L"Quit" : L"退出"));
      SetForegroundWindow(hwnd);
      const UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      if (selected == 1) Restore();
      if (selected == 2) RequestQuit();
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
