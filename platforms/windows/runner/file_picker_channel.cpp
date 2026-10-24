#include "file_picker_channel.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <utility>

#include "utils.h"

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* Field(const EncodableMap& map, const char* key) {
  const auto value = map.find(EncodableValue(key));
  return value == map.end() ? nullptr : &value->second;
}

bool ReadText(const EncodableValue* value, std::wstring* text) {
  if (!value || std::holds_alternative<std::monostate>(*value)) return true;
  const auto utf8 = std::get_if<std::string>(value);
  if (!utf8 || utf8->find('\0') != std::string::npos || utf8->size() > 131072) return false;
  if (utf8->empty()) return true;
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      utf8->data(), static_cast<int>(utf8->size()), nullptr, 0);
  if (!length) return false;
  text->resize(length);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8->data(),
      static_cast<int>(utf8->size()), text->data(), length) == length;
}

bool ReadOptions(const EncodableValue* value, lanflow::FilePickerOptions* options) {
  const auto map = value ? std::get_if<EncodableMap>(value) : nullptr;
  if (!map) return false;
  if (const auto multiple = Field(*map, "multiple")) {
    const auto boolean = std::get_if<bool>(multiple);
    if (!boolean) return false;
    options->multiple = *boolean;
  }
  if (!ReadText(Field(*map, "initialDirectory"), &options->initial_directory) ||
      !ReadText(Field(*map, "confirmButtonText"), &options->confirm_label)) return false;
  const auto raw_filters = Field(*map, "filters");
  if (!raw_filters) return true;
  const auto filters = std::get_if<EncodableList>(raw_filters);
  if (!filters || filters->size() > 100) return false;
  for (const auto& raw_filter : *filters) {
    const auto filter = std::get_if<EncodableMap>(&raw_filter);
    if (!filter) return false;
    lanflow::FilePickerFilter parsed;
    if (!ReadText(Field(*filter, "label"), &parsed.label)) return false;
    const auto raw_extensions = Field(*filter, "extensions");
    const auto extensions = raw_extensions ? std::get_if<EncodableList>(raw_extensions) : nullptr;
    if (!extensions || extensions->size() > 1000) return false;
    for (const auto& raw_extension : *extensions) {
      std::wstring extension;
      if (!ReadText(&raw_extension, &extension) || extension.empty() ||
          extension.find_first_of(L";*?/\\:\"<>|\r\n") != std::wstring::npos) return false;
      parsed.extensions.push_back(std::move(extension));
    }
    options->filters.push_back(std::move(parsed));
  }
  return true;
}
}  // namespace

FilePickerChannel::FilePickerChannel(HWND owner, flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "lanflow/file_picker", &flutter::StandardMethodCodec::GetInstance())),
      picker_(owner) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "cancelOpenFiles") {
      picker_.Cancel();
      result->Success();
      return;
    }
    if (call.method_name() != "openFiles") { result->NotImplemented(); return; }
    lanflow::FilePickerOptions options;
    if (!ReadOptions(call.arguments(), &options)) {
      result->Error("ARGUMENT", "Invalid file selection options");
      return;
    }
    auto reply = std::shared_ptr<flutter::MethodResult<EncodableValue>>(std::move(result));
    const bool started = picker_.Open(std::move(options), [reply](lanflow::FilePickerResult selected) {
      if (selected.status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        reply->Success(EncodableValue(EncodableList{}));
        return;
      }
      if (FAILED(selected.status)) {
        reply->Error("FILE_PICKER", "Cannot open the file selection dialog",
            EncodableValue(static_cast<int32_t>(selected.status)));
        return;
      }
      EncodableList paths;
      paths.reserve(selected.paths.size());
      for (const auto& path : selected.paths) {
        auto utf8 = Utf8FromUtf16(path.c_str());
        if (utf8.empty()) {
          reply->Error("FILE_PICKER", "Cannot read the selected file path");
          return;
        }
        paths.emplace_back(std::move(utf8));
      }
      reply->Success(EncodableValue(std::move(paths)));
    });
    if (!started) reply->Error("PICKER_BUSY", "A file selection dialog is already open");
  });
}

FilePickerChannel::~FilePickerChannel() {
  picker_.Shutdown();
  channel_->SetMethodCallHandler(nullptr);
}

bool FilePickerChannel::HandleMessage(UINT message, WPARAM token) {
  return picker_.HandleMessage(message, token);
}

void FilePickerChannel::Cancel() { picker_.Cancel(); }
