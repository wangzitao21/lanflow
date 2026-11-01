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

std::vector<std::string> ReadFileDrop(HDROP drop) {
  if (!drop) throw std::runtime_error("Cannot read clipboard files");
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  if (count > 10000) throw std::runtime_error("Too many clipboard files");
  std::vector<std::string> paths;
  paths.reserve(count);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    if (!length || length > 32767) throw std::runtime_error("Invalid clipboard file path");
    std::vector<wchar_t> path(length + 1);
    if (DragQueryFileW(drop, index, path.data(), length + 1) != length) {
      throw std::runtime_error("Cannot read clipboard file path");
    }
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        path.data(), static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    if (!size) throw std::runtime_error("Invalid clipboard file path");
    std::string utf8(size, '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
        static_cast<int>(length), utf8.data(), size, nullptr, nullptr)) {
      throw std::runtime_error("Cannot decode clipboard file path");
    }
    paths.push_back(std::move(utf8));
  }
  return paths;
}

std::vector<std::string> ReadClipboardFiles(HWND window) {
  if (!IsClipboardFormatAvailable(CF_HDROP)) return {};
  if (!OpenClipboard(window)) throw std::runtime_error("Clipboard is busy; please paste again");
  struct ClipboardLock { ~ClipboardLock() { CloseClipboard(); } } lock;
  // Clipboard memory belongs to its owner; copy paths before releasing the lock.
  return ReadFileDrop(static_cast<HDROP>(GetClipboardData(CF_HDROP)));
}

void WriteClipboardImage(HWND window, const std::vector<uint8_t>& png,
                         const std::vector<uint8_t>& rgba, int width, int height) {
  const auto pixels = static_cast<int64_t>(width) * height;
  if (width <= 0 || height <= 0 || pixels > 16 * 1024 * 1024 ||
      rgba.size() != static_cast<size_t>(pixels) * 4 || png.size() > kMaxBytes) {
    throw std::runtime_error("Clipboard image is too large or invalid");
  }
  ValidatePngDimensions(png.data(), png.size());
  using Memory = std::unique_ptr<void, decltype(&GlobalFree)>;
  auto allocate = [](SIZE_T size) -> Memory {
    auto handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size);
    if (!handle) throw std::runtime_error("Cannot allocate clipboard image");
    return Memory(handle, GlobalFree);
  };
  auto png_data = allocate(png.size());
  auto dib = allocate(sizeof(BITMAPV5HEADER) + rgba.size());
  auto legacy = allocate(sizeof(BITMAPINFOHEADER) + rgba.size());
  auto locked_png = GlobalLock(png_data.get());
  if (!locked_png) throw std::runtime_error("Cannot access clipboard memory");
  std::memcpy(locked_png, png.data(), png.size());
  GlobalUnlock(png_data.get());
  auto header = static_cast<BITMAPV5HEADER*>(GlobalLock(dib.get()));
  if (!header) throw std::runtime_error("Cannot access clipboard memory");
  header->bV5Size = sizeof(BITMAPV5HEADER);
  header->bV5Width = width;
  header->bV5Height = -height;
  header->bV5Planes = 1;
  header->bV5BitCount = 32;
  header->bV5Compression = BI_BITFIELDS;
  header->bV5SizeImage = static_cast<DWORD>(rgba.size());
  header->bV5RedMask = 0x00FF0000;
  header->bV5GreenMask = 0x0000FF00;
  header->bV5BlueMask = 0x000000FF;
  header->bV5AlphaMask = 0xFF000000;
  header->bV5CSType = LCS_sRGB;
  auto bgra = reinterpret_cast<uint8_t*>(header + 1);
  for (size_t i = 0; i < rgba.size(); i += 4) {
    bgra[i] = rgba[i + 2]; bgra[i + 1] = rgba[i + 1];
    bgra[i + 2] = rgba[i]; bgra[i + 3] = rgba[i + 3];
  }
  GlobalUnlock(dib.get());
  auto flat = static_cast<BITMAPINFOHEADER*>(GlobalLock(legacy.get()));
  if (!flat) throw std::runtime_error("Cannot access clipboard memory");
  flat->biSize = sizeof(BITMAPINFOHEADER);
  flat->biWidth = width; flat->biHeight = -height;
  flat->biPlanes = 1; flat->biBitCount = 32;
  flat->biCompression = BI_RGB;
  flat->biSizeImage = static_cast<DWORD>(rgba.size());
  auto opaque = reinterpret_cast<uint8_t*>(flat + 1);
  for (size_t i = 0; i < rgba.size(); i += 4) {
    const unsigned alpha = rgba[i + 3];
    for (size_t c = 0; c < 3; ++c) {
      opaque[i + c] = static_cast<uint8_t>((rgba[i + 2 - c] * alpha + 255 * (255 - alpha) + 127) / 255);
    }
    opaque[i + 3] = 255;
  }
  GlobalUnlock(legacy.get());
  const auto png_format = RegisterClipboardFormatW(L"PNG");
  if (!png_format || !OpenClipboard(window)) throw std::runtime_error("Clipboard is busy");
  struct ClipboardLock { ~ClipboardLock() { CloseClipboard(); } } lock;
  if (!EmptyClipboard()) throw std::runtime_error("Cannot clear clipboard");
  auto publish = [](UINT format, Memory& data) {
    if (!SetClipboardData(format, data.get())) throw std::runtime_error("Cannot copy image to clipboard");
    data.release();
  };
  publish(png_format, png_data);
  publish(CF_DIBV5, dib);
  publish(CF_DIB, legacy);
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
