#include "clipboard_bridge.h"

#include <wincodec.h>
#include <wrl/client.h>
#include <cstring>
#include <stdexcept>
#include <mutex>
#include <thread>
#include <utility>

using Microsoft::WRL::ComPtr;
namespace {
constexpr SIZE_T kMaxBytes = 64 * 1024 * 1024;
void Check(HRESULT result) {
  if (FAILED(result)) throw std::runtime_error("Cannot read clipboard image");
}
void ValidateBitmap(HBITMAP bitmap) {
  BITMAP info{};
  if (!GetObject(bitmap, sizeof(info), &info) || info.bmWidth <= 0 ||
      info.bmHeight <= 0 || static_cast<int64_t>(info.bmWidth) * info.bmHeight > 64000000) {
    throw std::runtime_error("Clipboard image is too large or invalid");
  }
}
void ValidatePngDimensions(const uint8_t* data, SIZE_T size) {
  if (size < 33 || std::memcmp(data + 12, "IHDR", 4) != 0) {
    throw std::runtime_error("Clipboard PNG is invalid");
  }
  auto number = [data](size_t offset) {
    return (uint64_t(data[offset]) << 24) | (uint64_t(data[offset + 1]) << 16) |
        (uint64_t(data[offset + 2]) << 8) | data[offset + 3];
  };
  const auto width = number(16), height = number(20);
  if (!width || !height || width > 64000000 || height > 64000000 || width * height > 64000000) {
    throw std::runtime_error("Clipboard image is too large or invalid");
  }
}
}

std::vector<uint8_t> BitmapToPng(HBITMAP bitmap) {
  ValidateBitmap(bitmap);
  ComPtr<IWICImagingFactory> factory;
  Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
  ComPtr<IWICBitmap> source;
  // CF_BITMAP does not specify alpha. Native PNG is preferred when available.
  Check(factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &source));
  ComPtr<IStream> stream;
  Check(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
  ComPtr<IWICBitmapEncoder> encoder;
  Check(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder));
  Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
  ComPtr<IWICBitmapFrameEncode> frame;
  Check(encoder->CreateNewFrame(&frame, nullptr));
  Check(frame->Initialize(nullptr));
  Check(frame->WriteSource(source.Get(), nullptr));
  Check(frame->Commit());
  Check(encoder->Commit());
  STATSTG stat{};
  Check(stream->Stat(&stat, STATFLAG_NONAME));
  if (stat.cbSize.QuadPart > kMaxBytes) throw std::runtime_error("Clipboard image exceeds 64 MB");
  const auto size = static_cast<SIZE_T>(stat.cbSize.QuadPart);
  HGLOBAL global = nullptr;
  Check(GetHGlobalFromStream(stream.Get(), &global));
  auto data = static_cast<const uint8_t*>(GlobalLock(global));
  if (!data) throw std::runtime_error("Cannot access encoded image");
  struct EncodedDataLock { HGLOBAL handle; ~EncodedDataLock() { GlobalUnlock(handle); } } unlock{global};
  std::vector<uint8_t> png(data, data + size);
  return png;
}

ClipboardSnapshot SnapshotBitmap(HBITMAP bitmap) {
  ValidateBitmap(bitmap);
  auto owned = static_cast<HBITMAP>(CopyImage(bitmap, IMAGE_BITMAP, 0, 0, LR_CREATEDIBSECTION));
  if (!owned) throw std::runtime_error("Cannot copy clipboard image");
  ClipboardSnapshot snapshot;
  snapshot.bitmap = std::shared_ptr<void>(owned, [](void* object) { DeleteObject(static_cast<HBITMAP>(object)); });
  return snapshot;
}

std::optional<ClipboardSnapshot> ReadClipboardSnapshot(HWND window) {
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (!IsClipboardFormatAvailable(png_format) && !IsClipboardFormatAvailable(CF_BITMAP)) return std::nullopt;
  if (!OpenClipboard(window)) throw std::runtime_error("Clipboard is busy; please paste again");
  struct ClipboardLock { ~ClipboardLock() { CloseClipboard(); } } lock;
  if (IsClipboardFormatAvailable(png_format)) {
    const auto handle = GetClipboardData(png_format);
    const auto size = GlobalSize(handle);
    if (size > kMaxBytes) throw std::runtime_error("Clipboard image exceeds 64 MB");
    const auto data = static_cast<const uint8_t*>(GlobalLock(handle));
    if (data) {
      constexpr uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
      if (size >= sizeof(signature) && std::memcmp(data, signature, sizeof(signature)) == 0) {
        struct GlobalDataLock { HGLOBAL handle; ~GlobalDataLock() { GlobalUnlock(handle); } } unlock{handle};
        ValidatePngDimensions(data, size);
        return ClipboardSnapshot{std::vector<uint8_t>(data, data + size), nullptr};
      }
      GlobalUnlock(handle);
    }
  }
  const auto bitmap = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
  if (!bitmap) return std::nullopt;
  return SnapshotBitmap(bitmap);
}

std::optional<std::vector<uint8_t>> EncodeClipboardSnapshot(std::optional<ClipboardSnapshot> snapshot) {
  if (!snapshot) return std::nullopt;
  if (!snapshot->png.empty()) return std::move(snapshot->png);
  return BitmapToPng(static_cast<HBITMAP>(snapshot->bitmap.get()));
}

std::optional<std::vector<uint8_t>> ReadClipboardPng(HWND window) {
  return EncodeClipboardSnapshot(ReadClipboardSnapshot(window));
}

struct AsyncClipboard::State {
  std::mutex mutex;
  HWND owner;
  Encoder encoder;
  bool active = false;
  bool shutdown = false;
  std::uint64_t token = 0;
  std::optional<ClipboardResult> completed;
};

AsyncClipboard::AsyncClipboard(HWND owner, Encoder encoder)
    : state_(std::make_shared<State>()), platform_thread_(GetCurrentThreadId()) {
  state_->owner = owner;
  state_->encoder = std::move(encoder);
}
AsyncClipboard::~AsyncClipboard() { Shutdown(); }

bool AsyncClipboard::Encode(std::optional<ClipboardSnapshot> snapshot, Completion completion) {
  if (GetCurrentThreadId() != platform_thread_) return false;
  std::uint64_t token;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->active || state_->shutdown) return false;
    state_->active = true;
    token = ++state_->token;
  }
  completion_ = std::move(completion);
  try {
    std::thread(&AsyncClipboard::Run, state_, token, std::move(snapshot)).detach();
  } catch (...) {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->completed = ClipboardResult{std::nullopt, "Cannot start clipboard conversion"};
    }
    HandleMessage(kCompletedMessage, static_cast<WPARAM>(token));
  }
  return true;
}

bool AsyncClipboard::HandleMessage(UINT message, WPARAM token) {
  if (message != kCompletedMessage || GetCurrentThreadId() != platform_thread_) return false;
  std::optional<ClipboardResult> result;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->shutdown || token != state_->token || !state_->completed) return true;
    result = std::move(state_->completed);
    state_->completed.reset();
    state_->active = false;
  }
  auto callback = std::move(completion_);
  completion_ = nullptr;
  if (callback) callback(std::move(*result));
  return true;
}

void AsyncClipboard::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->shutdown = true;
    state_->owner = nullptr;
    state_->completed.reset();
  }
  completion_ = nullptr;
}

void AsyncClipboard::Run(std::shared_ptr<State> state, std::uint64_t token, std::optional<ClipboardSnapshot> snapshot) {
  ClipboardResult result;
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) {
    result.error = "Cannot initialize clipboard conversion";
  } else {
    try { result.png = state->encoder(std::move(snapshot)); }
    catch (const std::exception& error) { result.error = error.what(); }
    catch (...) { result.error = "Cannot convert clipboard image"; }
    CoUninitialize();
  }
  HWND owner;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->shutdown || token != state->token) return;
    state->completed = std::move(result);
    owner = state->owner;
  }
  if (owner && !PostMessageW(owner, kCompletedMessage, static_cast<WPARAM>(token), 0)) {
    SendNotifyMessageW(owner, kCompletedMessage, static_cast<WPARAM>(token), 0);
  }
}
