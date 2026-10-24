#define NOMINMAX
#include "../../platforms/windows/runner/window_geometry.h"
#include <cassert>
#include <iostream>

int main() {
  const RECT work{0, 0, 1920, 1040};
  auto same = FitWindowBounds({80, 80, 1260, 860}, work, 96);
  assert(same.left == 80 && same.top == 80 && same.right == 1260);
  auto disconnected = FitWindowBounds({3000, -800, 4180, -20}, work, 96);
  assert(disconnected.left == 740 && disconnected.top == 0);
  assert(disconnected.right <= work.right && disconnected.bottom <= work.bottom);
  auto scaled = FitWindowBounds({10, 10, 110, 110}, work, 144);
  assert(scaled.right - scaled.left == 1320 && scaled.bottom - scaled.top == 840);
  auto laptop = FitWindowBounds({0, 0, 3000, 2000}, {0, 40, 1280, 720}, 192);
  assert(laptop.top == 40 && laptop.right == 1280 && laptop.bottom == 720);
  auto left = FitWindowBounds({-1800, 100, -620, 880}, {-1920, 0, 0, 1080}, 96);
  assert(left.left == -1800 && left.top == 100);
  std::cout << "Window geometry: 5 cases passed\n";
}
