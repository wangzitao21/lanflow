#include "../../platforms/windows/runner/clipboard_bridge.h"
#include <wincodec.h>
#include <shlobj.h>
#include <wrl/client.h>
#include <iostream>
#include <stdexcept>
#include <chrono>
#include <future>
#include <thread>
#include <cstring>

using Microsoft::WRL::ComPtr;
void Check(HRESULT hr) {
  if (FAILED(hr)) throw std::runtime_error("WIC test operation failed");
}

void TestFileDrop() {
  const std::wstring first = L"C:\\Photos\\\u65c5\u884c \u7167\u7247 \U0001F308.jpg";
  const std::wstring second = L"C:\\" + std::wstring(280, L'a') + L"\\second.png";
  const auto bytes = sizeof(DROPFILES) + (first.size() + second.size() + 3) * sizeof(wchar_t);
  auto memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
  if (!memory) throw std::runtime_error("Cannot allocate file-drop fixture");
  auto drop = static_cast<DROPFILES*>(GlobalLock(memory));
  if (!drop) throw std::runtime_error("Cannot lock file-drop fixture");
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  auto paths = reinterpret_cast<wchar_t*>(drop + 1);
  std::memcpy(paths, first.c_str(), (first.size() + 1) * sizeof(wchar_t));
  std::memcpy(paths + first.size() + 1, second.c_str(), (second.size() + 1) * sizeof(wchar_t));
  GlobalUnlock(memory);
  const auto copied = ReadFileDrop(static_cast<HDROP>(memory));
  GlobalFree(memory);
  const std::vector<std::string> expected = {
    u8"C:\\Photos\\\u65c5\u884c \u7167\u7247 \U0001F308.jpg",
    "C:\\" + std::string(280, 'a') + "\\second.png",
  };
  if (copied != expected) throw std::runtime_error("File-drop paths, Unicode or long names changed");

  const char legacy[] = "C:\\Photos\\legacy.jpg\0C:\\Photos\\other.png\0";
  memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + sizeof(legacy));
  drop = static_cast<DROPFILES*>(GlobalLock(memory));
  if (!drop) throw std::runtime_error("Cannot allocate ANSI file-drop fixture");
  drop->pFiles = sizeof(DROPFILES);
  std::memcpy(drop + 1, legacy, sizeof(legacy));
  GlobalUnlock(memory);
  const auto ansi = ReadFileDrop(static_cast<HDROP>(memory));
  GlobalFree(memory);
  if (ansi != std::vector<std::string>{"C:\\Photos\\legacy.jpg", "C:\\Photos\\other.png"}) {
    throw std::runtime_error("ANSI file-drop paths changed");
  }
}

void TestAsyncLifecycle() {
  HWND window = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!window) throw std::runtime_error("Cannot create test message window");
  const DWORD platform = GetCurrentThreadId();
  std::promise<void> entered, release;
  auto gate = release.get_future().share();
  bool completed = false;
  AsyncClipboard encoder(window, [&](auto) -> std::optional<std::vector<uint8_t>> {
    if (GetCurrentThreadId() == platform) throw std::runtime_error("Encoding ran on the platform thread");
    entered.set_value();
    gate.wait();
    return std::vector<uint8_t>{1, 2, 3};
  });
  if (!encoder.Encode(std::nullopt, [&](ClipboardResult result) {
    if (GetCurrentThreadId() != platform || !result.error.empty() || !result.png || result.png->size() != 3) {
      throw std::runtime_error("Invalid asynchronous clipboard result");
    }
    completed = true;
  })) throw std::runtime_error("Clipboard request rejected");
  if (entered.get_future().wait_for(std::chrono::seconds(2)) != std::future_status::ready || completed) {
    throw std::runtime_error("Clipboard conversion did not run independently");
  }
  if (encoder.Encode(std::nullopt, [](auto) {})) throw std::runtime_error("Concurrent conversion was accepted");
  release.set_value();
  const auto deadline = GetTickCount64() + 2000;
  while (!completed && GetTickCount64() < deadline) {
    MSG message;
    while (PeekMessageW(&message, window, 0, 0, PM_REMOVE)) encoder.HandleMessage(message.message, message.wParam);
    Sleep(1);
  }
  if (!completed) throw std::runtime_error("Clipboard result was not delivered on the platform thread");

  std::promise<void> started, finish, finished;
  auto finish_gate = finish.get_future().share();
  bool stale_callback = false;
  AsyncClipboard closing(window, [&](auto) -> std::optional<std::vector<uint8_t>> {
    started.set_value();
    finish_gate.wait();
    finished.set_value();
    return std::nullopt;
  });
  closing.Encode(std::nullopt, [&](auto) { stale_callback = true; });
  started.get_future().wait();
  closing.Shutdown();
  finish.set_value();
  finished.get_future().wait();
  closing.HandleMessage(AsyncClipboard::kCompletedMessage, 1);
  if (stale_callback) throw std::runtime_error("Clipboard callback outlived shutdown");
  encoder.Shutdown();
  DestroyWindow(window);
}

int main() {
  Check(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
  try {
    // Create a screenshot-like DIB without touching the user's clipboard.
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = 2;
    info.bmiHeader.biHeight = -2;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    auto bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap || !pixels) throw std::runtime_error("Cannot create test bitmap");
    auto colors = static_cast<uint32_t*>(pixels);
    colors[0] = 0x00CC6622;
    colors[1] = 0x0000FF00;
    colors[2] = 0x000000FF;
    colors[3] = 0x00FFFFFF;
    auto snapshot = SnapshotBitmap(bitmap);
    DeleteObject(bitmap);
    // The owned snapshot remains valid after the clipboard owner frees its bitmap.
    auto png = *EncodeClipboardSnapshot(std::move(snapshot));
    ComPtr<IWICImagingFactory> factory;
    Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
    ComPtr<IWICStream> stream;
    Check(factory->CreateStream(&stream));
    Check(stream->InitializeFromMemory(png.data(), static_cast<DWORD>(png.size())));
    ComPtr<IWICBitmapDecoder> decoder;
    Check(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder));
    ComPtr<IWICBitmapFrameDecode> frame;
    Check(decoder->GetFrame(0, &frame));
    UINT width = 0, height = 0;
    Check(frame->GetSize(&width, &height));
    if (width != 2 || height != 2) throw std::runtime_error("Image dimensions changed");
    ComPtr<IWICFormatConverter> converter;
    Check(factory->CreateFormatConverter(&converter));
    Check(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
        nullptr, 0, WICBitmapPaletteTypeCustom));
    uint32_t decoded[4]{};
    Check(converter->CopyPixels(nullptr, 8, sizeof(decoded), reinterpret_cast<BYTE*>(decoded)));
    const uint32_t expected[] = {0xFFCC6622, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF};
    for (int i = 0; i < 4; ++i) {
      if (decoded[i] != expected[i]) throw std::runtime_error("Pixel color or orientation changed");
    }
    std::cout << "Native screenshot-to-PNG dimensions, orientation and colors passed\n";
    TestAsyncLifecycle();
    std::cout << "Clipboard background encoding and shutdown lifecycle passed\n";
    TestFileDrop();
    std::cout << "Explorer file-list Unicode, multiple files and long paths passed\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    CoUninitialize();
    return 1;
  }
  CoUninitialize();
  return 0;
}
