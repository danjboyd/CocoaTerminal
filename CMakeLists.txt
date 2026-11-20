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
  src/COTConPTY.cpp
  src/COTGLRenderer.cpp
  src/COTTerminalConfiguration.mm
  src/COTTerminalGrid.cpp
  src/COTTerminalSession.mm
  src/COTTerminalTheme.mm
  src/COTTerminalView.mm
)

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
    target_include_directories(CocoaTerminal PRIVATE ${COT_EGL_INCLUDE_DIRS})
    target_link_directories(CocoaTerminal PUBLIC ${COT_EGL_LIBRARY_DIRS})
    target_link_libraries(CocoaTerminal PUBLIC ${COT_EGL_LIBRARIES})
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

  add_executable(CocoaTerminalKeyboardLayoutTests tests/COTKeyboardLayoutTests.mm)
  set_target_properties(CocoaTerminalKeyboardLayoutTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalKeyboardLayoutTests PRIVATE CocoaTerminal::CocoaTerminal)
  if(WIN32)
    target_link_libraries(CocoaTerminalKeyboardLayoutTests PRIVATE imm32)
  endif()
  add_test(NAME CocoaTerminalKeyboardLayoutTests COMMAND CocoaTerminalKeyboardLayoutTests)

  add_executable(CocoaTerminalCaptureTests tests/COTTerminalCaptureTests.mm)
  set_target_properties(CocoaTerminalCaptureTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalCaptureTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalCaptureTests COMMAND CocoaTerminalCaptureTests)

  add_executable(CocoaTerminalKeyTests tests/COTTerminalKeyTests.mm)
  set_target_properties(CocoaTerminalKeyTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalKeyTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalKeyTests COMMAND CocoaTerminalKeyTests)
endif()
