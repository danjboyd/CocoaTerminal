# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Daniel Boyd

cmake_minimum_required(VERSION 3.24)

project(CocoaTerminal
  VERSION 0.1.0
  LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

option(COCOATERMINAL_BUILD_DEMO "Build the CocoaTerminal demo app" ON)
option(COCOATERMINAL_BUILD_TESTS "Build CocoaTerminal tests" ON)
# The OpenGL renderer (COCOATERMINAL_RENDERER=gl at run time). On by default on Windows; elsewhere it needs EGL,
# FreeType and fontconfig, and is off until it has been run on Linux.
if(WIN32)
  option(COCOATERMINAL_GL_RENDERER "Build the OpenGL renderer" ON)
else()
  option(COCOATERMINAL_GL_RENDERER "Build the OpenGL renderer" OFF)
endif()

include(GNUInstallDirs)
find_package(PkgConfig REQUIRED)

pkg_check_modules(VTERM REQUIRED vterm)

if(APPLE)
  set(COCOATERMINAL_PLATFORM_MACOS YES)
else()
  pkg_check_modules(GNUSTEP_GUI REQUIRED gnustep-gui)
  set(COCOATERMINAL_PLATFORM_GNUSTEP YES)
endif()

add_library(CocoaTerminal
  src/COTCairoCells.mm
  src/COTConPTY.cpp
  src/COTGLRenderer.cpp
  src/COTTerminalConfiguration.mm
  src/COTTerminalGrid.cpp
  src/COTTransportWriter.cpp
  src/COTSessionLifecycle.cpp
  src/COTTerminalSession.mm
  src/COTTerminalTheme.mm
  src/COTTerminalView.mm
)
if(NOT WIN32)
  # The forkpty child's plan (Unix only; Windows starts the shell through ConPTY, src/COTConPTY.cpp).
  target_sources(CocoaTerminal PRIVATE src/COTSpawnPlan.cpp)
endif()

add_library(CocoaTerminal::CocoaTerminal ALIAS CocoaTerminal)

if(COCOATERMINAL_GL_RENDERER AND NOT APPLE)
  pkg_check_modules(COT_FREETYPE REQUIRED freetype2 fontconfig)
  target_sources(CocoaTerminal PRIVATE src/COTGlyphsFreeType.cpp)
  target_compile_definitions(CocoaTerminal PRIVATE COCOATERMINAL_GL_RENDERER=1)
  # pkg-config lists the toolchain's own include directory too; as an -I it would come before libc++'s headers.
  list(FILTER COT_FREETYPE_INCLUDE_DIRS EXCLUDE REGEX "[/\\]include$")
  target_include_directories(CocoaTerminal PRIVATE ${COT_FREETYPE_INCLUDE_DIRS})
  target_link_directories(CocoaTerminal PUBLIC ${COT_FREETYPE_LIBRARY_DIRS})
  target_link_libraries(CocoaTerminal PUBLIC ${COT_FREETYPE_LIBRARIES})
  if(WIN32)
    target_sources(CocoaTerminal PRIVATE src/COTGLContextWGL.cpp src/COTGlyphsDirectWrite.cpp)
    target_link_libraries(CocoaTerminal PUBLIC opengl32 gdi32 dwrite)
  else()
    pkg_check_modules(COT_EGL REQUIRED egl)
    target_sources(CocoaTerminal PRIVATE src/COTGLContextEGL.cpp)
    # EGL and GLX are loaded at run time (COTGLContextEGL.cpp), never linked: a program built with the OpenGL renderer
    # still starts where there's no libEGL or libGL, and draws with Cairo. Only their headers are needed here.
    target_include_directories(CocoaTerminal PRIVATE ${COT_EGL_INCLUDE_DIRS})
    target_link_libraries(CocoaTerminal PUBLIC ${CMAKE_DL_LIBS})
    # GLX, to draw straight into an NSOpenGLView (GNUstep's x11 back end draws it with GLX). Optional: without it the
    # renderer draws off screen through EGL and the view shows the image.
    pkg_check_modules(COT_GLX QUIET gl)
    if(COT_GLX_FOUND)
      target_compile_definitions(CocoaTerminal PRIVATE COCOATERMINAL_GLX=1)
      target_include_directories(CocoaTerminal PRIVATE ${COT_GLX_INCLUDE_DIRS})
    endif()
  endif()
endif()

target_include_directories(CocoaTerminal
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)

target_compile_features(CocoaTerminal PUBLIC cxx_std_17)

target_include_directories(CocoaTerminal PRIVATE ${VTERM_INCLUDE_DIRS})
# PUBLIC: -lvterm reaches whatever links the static library, which needs its directory too.
target_link_directories(CocoaTerminal PUBLIC ${VTERM_LIBRARY_DIRS})
target_link_libraries(CocoaTerminal PRIVATE ${VTERM_LIBRARIES})

if(APPLE)
  target_compile_definitions(CocoaTerminal PRIVATE COCOATERMINAL_PLATFORM_MACOS=1)
  target_link_libraries(CocoaTerminal PUBLIC "-framework Cocoa")
else()
  target_compile_definitions(CocoaTerminal PRIVATE COCOATERMINAL_PLATFORM_GNUSTEP=1)
  set(COCOATERMINAL_GNUSTEP_INCLUDE_DIRS ${GNUSTEP_GUI_INCLUDE_DIRS})
  set(COCOATERMINAL_GNUSTEP_CFLAGS_OTHER ${GNUSTEP_GUI_CFLAGS_OTHER})
  list(REMOVE_ITEM COCOATERMINAL_GNUSTEP_INCLUDE_DIRS ".")
  list(REMOVE_ITEM COCOATERMINAL_GNUSTEP_CFLAGS_OTHER "-MMD" "-MP" "-fobjc-nonfragile-abi")
  target_include_directories(CocoaTerminal PUBLIC ${COCOATERMINAL_GNUSTEP_INCLUDE_DIRS})
  foreach(flag IN LISTS COCOATERMINAL_GNUSTEP_CFLAGS_OTHER)
    target_compile_options(CocoaTerminal PUBLIC "$<$<OR:$<COMPILE_LANGUAGE:OBJC>,$<COMPILE_LANGUAGE:OBJCXX>>:${flag}>")
  endforeach()
  target_compile_options(CocoaTerminal PUBLIC "$<$<OR:$<COMPILE_LANGUAGE:OBJC>,$<COMPILE_LANGUAGE:OBJCXX>>:-Wno-nullability-completeness>")
  target_link_directories(CocoaTerminal PUBLIC ${GNUSTEP_GUI_LIBRARY_DIRS})
  target_link_options(CocoaTerminal PUBLIC ${GNUSTEP_GUI_LDFLAGS_OTHER})
  target_link_libraries(CocoaTerminal PUBLIC ${GNUSTEP_GUI_LIBRARIES})
  if(NOT "gnustep-gui" IN_LIST GNUSTEP_GUI_LIBRARIES)
    # MSYS2's gnustep-gui.pc lists only gnustep-base.
    target_link_libraries(CocoaTerminal PUBLIC gnustep-gui)
  endif()
  if(NOT WIN32)
    target_link_libraries(CocoaTerminal PUBLIC util)  # forkpty
  else()
    target_link_libraries(CocoaTerminal PUBLIC shell32)  # ShellExecuteW opens links
    target_link_libraries(CocoaTerminal PUBLIC imm32)  # placing the IME's composition window
  endif()
  target_link_libraries(CocoaTerminal PUBLIC dispatch)
endif()

install(TARGETS CocoaTerminal
  EXPORT CocoaTerminalTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

install(DIRECTORY include/CocoaTerminal
  DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(COCOATERMINAL_BUILD_DEMO)
  add_executable(CocoaTerminalDemo demo/main.mm demo/COTConfigLoader.mm)
  set_target_properties(CocoaTerminalDemo PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalDemo PRIVATE CocoaTerminal::CocoaTerminal)

  add_executable(CocoaTerminalBench bench/COTBench.mm bench/COTBenchMemory.cpp)
  if(WIN32)
    target_link_libraries(CocoaTerminalBench PRIVATE psapi)

    # Do OpenGL views work in GNUstep windows on Windows? Opens windows and reads the screen; not run by ctest.
    add_executable(CocoaTerminalGLCheck bench/COTGLCheck.mm bench/COTGLCheckWin.cpp)
    set_target_properties(CocoaTerminalGLCheck PROPERTIES LINKER_LANGUAGE OBJCXX)
    target_link_libraries(CocoaTerminalGLCheck PRIVATE CocoaTerminal::CocoaTerminal opengl32 psapi gdi32 user32)
  elseif(NOT APPLE)
    # The same check on X11 (GNUstep's x11 backend built with GLX). XTest and X-Resource are loaded at run time.
    add_executable(CocoaTerminalGLCheck bench/COTGLCheck.mm bench/COTGLCheckX11.cpp)
    set_target_properties(CocoaTerminalGLCheck PROPERTIES LINKER_LANGUAGE OBJCXX)
    target_link_libraries(CocoaTerminalGLCheck PRIVATE CocoaTerminal::CocoaTerminal GL X11 ${CMAKE_DL_LIBS})
  endif()
  set_target_properties(CocoaTerminalBench PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalBench PRIVATE CocoaTerminal::CocoaTerminal)
endif()

if(COCOATERMINAL_BUILD_TESTS)
  enable_testing()
  add_executable(CocoaTerminalCoreTests tests/COTTerminalGridTests.cpp src/COTTerminalGrid.cpp)
  target_include_directories(CocoaTerminalCoreTests PRIVATE src ${VTERM_INCLUDE_DIRS})
  target_link_directories(CocoaTerminalCoreTests PRIVATE ${VTERM_LIBRARY_DIRS})
  target_link_libraries(CocoaTerminalCoreTests PRIVATE ${VTERM_LIBRARIES})
  target_compile_features(CocoaTerminalCoreTests PRIVATE cxx_std_17)
  add_test(NAME CocoaTerminalCoreTests COMMAND CocoaTerminalCoreTests)

  add_executable(CocoaTerminalGLRendererTests tests/COTGLRendererTests.cpp)
  set_target_properties(CocoaTerminalGLRendererTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalGLRendererTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalGLRendererTests COMMAND CocoaTerminalGLRendererTests)

  add_executable(CocoaTerminalThemeTests tests/COTTerminalThemeTests.mm)
  set_target_properties(CocoaTerminalThemeTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalThemeTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalThemeTests COMMAND CocoaTerminalThemeTests)

  add_executable(CocoaTerminalApplyThemeTests tests/COTTerminalApplyThemeTests.mm)
  set_target_properties(CocoaTerminalApplyThemeTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalApplyThemeTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalApplyThemeTests COMMAND CocoaTerminalApplyThemeTests)

  add_executable(CocoaTerminalSessionLifetimeTests tests/COTSessionLifetimeTests.mm)
  set_target_properties(CocoaTerminalSessionLifetimeTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalSessionLifetimeTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalSessionLifetimeTests COMMAND CocoaTerminalSessionLifetimeTests)

  add_executable(CocoaTerminalSessionShellTests tests/COTSessionShellTests.mm)
  set_target_properties(CocoaTerminalSessionShellTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalSessionShellTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalSessionShellTests COMMAND CocoaTerminalSessionShellTests)

  add_executable(CocoaTerminalAttributeTests tests/COTTerminalAttributeTests.mm)
  set_target_properties(CocoaTerminalAttributeTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalAttributeTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalAttributeTests COMMAND CocoaTerminalAttributeTests)

  add_executable(CocoaTerminalGlyphTests tests/COTTerminalGlyphTests.mm)
  set_target_properties(CocoaTerminalGlyphTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalGlyphTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalGlyphTests COMMAND CocoaTerminalGlyphTests)

  add_executable(CocoaTerminalFontTests tests/COTTerminalFontTests.mm)
  set_target_properties(CocoaTerminalFontTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalFontTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalFontTests COMMAND CocoaTerminalFontTests)

  add_executable(CocoaTerminalViewStyleTests tests/COTTerminalViewStyleTests.mm)
  set_target_properties(CocoaTerminalViewStyleTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalViewStyleTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalViewStyleTests COMMAND CocoaTerminalViewStyleTests)

  add_executable(CocoaTerminalSearchTests tests/COTTerminalSearchTests.mm)
  set_target_properties(CocoaTerminalSearchTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalSearchTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalSearchTests COMMAND CocoaTerminalSearchTests)

  add_executable(CocoaTerminalShellIntegrationTests tests/COTShellIntegrationTests.mm)
  set_target_properties(CocoaTerminalShellIntegrationTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalShellIntegrationTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalShellIntegrationTests COMMAND CocoaTerminalShellIntegrationTests)

  add_executable(CocoaTerminalKeyboardLayoutTests tests/COTKeyboardLayoutTests.mm)
  set_target_properties(CocoaTerminalKeyboardLayoutTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalKeyboardLayoutTests PRIVATE CocoaTerminal::CocoaTerminal)
  if(WIN32)
    target_link_libraries(CocoaTerminalKeyboardLayoutTests PRIVATE imm32)
  endif()
  add_test(NAME CocoaTerminalKeyboardLayoutTests COMMAND CocoaTerminalKeyboardLayoutTests)

  add_executable(CocoaTerminalRendererChoiceTests tests/COTRendererChoiceTests.mm)
  set_target_properties(CocoaTerminalRendererChoiceTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalRendererChoiceTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalRendererChoiceTests COMMAND CocoaTerminalRendererChoiceTests)

  add_executable(CocoaTerminalCaptureTests tests/COTTerminalCaptureTests.mm)
  set_target_properties(CocoaTerminalCaptureTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalCaptureTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalCaptureTests COMMAND CocoaTerminalCaptureTests)

  add_executable(CocoaTerminalCairoRenderTests tests/COTTerminalCairoRenderTests.mm)
  set_target_properties(CocoaTerminalCairoRenderTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalCairoRenderTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalCairoRenderTests COMMAND CocoaTerminalCairoRenderTests)

  add_executable(CocoaTerminalKeyTests tests/COTTerminalKeyTests.mm)
  set_target_properties(CocoaTerminalKeyTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalKeyTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalKeyTests COMMAND CocoaTerminalKeyTests)
endif()

if(COCOATERMINAL_BUILD_TESTS)
  add_executable(CocoaTerminalObserverTests tests/COTTerminalObserverTests.mm)
  set_target_properties(CocoaTerminalObserverTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalObserverTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalObserverTests COMMAND CocoaTerminalObserverTests)

  # Local disposable children only (each case has a 5 s alarm); no SSH/GUI/clipboard.
  # Linux only: it counts fds, children and zombies through /proc, which macOS hasn't got.
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    add_executable(CocoaTerminalChildTests tests/COTSessionChildTests.mm)
    set_target_properties(CocoaTerminalChildTests PROPERTIES LINKER_LANGUAGE OBJCXX)
    target_link_libraries(CocoaTerminalChildTests PRIVATE CocoaTerminal::CocoaTerminal)
    add_test(NAME CocoaTerminalChildTests COMMAND CocoaTerminalChildTests)
    set_tests_properties(CocoaTerminalChildTests PROPERTIES TIMEOUT 25)
  endif()
endif()

if(COCOATERMINAL_BUILD_TESTS)
  add_executable(CocoaTerminalWriterTests tests/COTTransportWriterTests.cpp src/COTTransportWriter.cpp)
  target_include_directories(CocoaTerminalWriterTests PRIVATE src)
  add_test(NAME CocoaTerminalWriterTests COMMAND CocoaTerminalWriterTests)
endif()

if(COCOATERMINAL_BUILD_TESTS AND NOT WIN32)
  # Unix child reaping (its cases use SIGHUP and SIGKILL statuses); Windows sessions use ConPTY instead.
  add_executable(CocoaTerminalLifecycleTests tests/COTSessionLifecycleTests.cpp src/COTSessionLifecycle.cpp)
  target_include_directories(CocoaTerminalLifecycleTests PRIVATE src)
  target_compile_features(CocoaTerminalLifecycleTests PRIVATE cxx_std_17)
  add_test(NAME CocoaTerminalLifecycleTests COMMAND CocoaTerminalLifecycleTests)
endif()

if(COCOATERMINAL_BUILD_TESTS AND NOT WIN32)
  # Plain fork() children in a scratch dir (5 s alarm); no PTY/SSH/GUI/clipboard.
  add_executable(CocoaTerminalSpawnTests tests/COTSpawnPlanTests.cpp src/COTSpawnPlan.cpp)
  target_include_directories(CocoaTerminalSpawnTests PRIVATE src)
  target_compile_features(CocoaTerminalSpawnTests PRIVATE cxx_std_17)
  add_test(NAME CocoaTerminalSpawnTests COMMAND CocoaTerminalSpawnTests)
  set_tests_properties(CocoaTerminalSpawnTests PROPERTIES TIMEOUT 15)
endif()

if(COCOATERMINAL_BUILD_TESTS)
  add_executable(CocoaTerminalFairnessTests tests/COTTransportFairnessTests.cpp src/COTTransportWriter.cpp)
  target_include_directories(CocoaTerminalFairnessTests PRIVATE src)
  add_test(NAME CocoaTerminalFairnessTests COMMAND CocoaTerminalFairnessTests)
endif()
