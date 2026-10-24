#ifndef RUNNER_FILE_PICKER_CHANNEL_H_
#define RUNNER_FILE_PICKER_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

#include "file_picker_bridge.h"

class FilePickerChannel {
 public:
  FilePickerChannel(HWND owner, flutter::BinaryMessenger* messenger);
  ~FilePickerChannel();
  bool HandleMessage(UINT message, WPARAM token);
  void Cancel();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  lanflow::AsyncFilePicker picker_;
};

#endif  // RUNNER_FILE_PICKER_CHANNEL_H_
