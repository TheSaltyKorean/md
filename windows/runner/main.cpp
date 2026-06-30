#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Portrait by default — these are documents, which read taller than wide —
  // but never larger than the monitor work area, so the bottom of the window
  // (and its controls) can't start off-screen on shorter 1366x768 displays.
  int desired_w = 900;
  int desired_h = 1180;
  int origin_x = 10;
  int origin_y = 10;
  RECT work_area;
  if (::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0)) {
    // Win32Window::Create treats the Point/Size as *logical* units and scales
    // them by dpi/96 before CreateWindow. SPI_GETWORKAREA reports *physical*
    // pixels, so convert the work area to logical units before clamping —
    // otherwise on >100% display scaling the clamped value is scaled again and
    // the window still opens taller than the monitor.
    double scale = ::GetDpiForSystem() / 96.0;
    if (scale <= 0) scale = 1.0;
    const int work_w = static_cast<int>((work_area.right - work_area.left) / scale);
    const int work_h = static_cast<int>((work_area.bottom - work_area.top) / scale);
    if (desired_w > work_w - 20) desired_w = work_w - 20;
    if (desired_h > work_h - 20) desired_h = work_h - 20;
    origin_x = static_cast<int>(work_area.left / scale) + 10;
    origin_y = static_cast<int>(work_area.top / scale) + 10;
  }
  Win32Window::Point origin(origin_x, origin_y);
  Win32Window::Size size(desired_w, desired_h);
  if (!window.Create(L"markdown_studio", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
