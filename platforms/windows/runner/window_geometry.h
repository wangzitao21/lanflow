#ifndef LANFLOW_WINDOW_GEOMETRY_H_
#define LANFLOW_WINDOW_GEOMETRY_H_

#include <windows.h>
#include <algorithm>
#include <cstdint>

// Stored bounds are in screen coordinates. A removed monitor or changed DPI
// must never leave the title bar or resize controls outside the work area.
inline RECT FitWindowBounds(const RECT& saved, const RECT& work, UINT dpi) {
  const auto work_width = std::max<int64_t>(1, int64_t(work.right) - work.left);
  const auto work_height = std::max<int64_t>(1, int64_t(work.bottom) - work.top);
  const auto width = std::clamp<int64_t>(
      int64_t(saved.right) - saved.left,
      std::min<int64_t>(MulDiv(880, dpi ? dpi : 96, 96), work_width),
      work_width);
  const auto height = std::clamp<int64_t>(
      int64_t(saved.bottom) - saved.top,
      std::min<int64_t>(MulDiv(560, dpi ? dpi : 96, 96), work_height),
      work_height);
  const auto left = std::clamp<int64_t>(saved.left, work.left, work.right - width);
  const auto top = std::clamp<int64_t>(saved.top, work.top, work.bottom - height);
  return {static_cast<LONG>(left), static_cast<LONG>(top),
          static_cast<LONG>(left + width), static_cast<LONG>(top + height)};
}

#endif
