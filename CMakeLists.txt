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
  src/COTTerminalConfiguration.mm
  src/COTTerminalGrid.cpp
  src/COTTerminalSession.mm
  src/COTTerminalTheme.mm
  src/COTTerminalView.mm
)

add_library(CocoaTerminal::CocoaTerminal ALIAS CocoaTerminal)

target_include_directories(CocoaTerminal
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)

target_compile_features(CocoaTerminal PUBLIC cxx_std_17)

target_include_directories(CocoaTerminal PRIVATE ${VTERM_INCLUDE_DIRS})
target_link_directories(CocoaTerminal PRIVATE ${VTERM_LIBRARY_DIRS})
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
  target_link_libraries(CocoaTerminal PUBLIC ${GNUSTEP_GUI_LIBRARIES} util)
endif()

install(TARGETS CocoaTerminal
  EXPORT CocoaTerminalTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

install(DIRECTORY include/CocoaTerminal
  DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(COCOATERMINAL_BUILD_DEMO)
  add_executable(CocoaTerminalDemo demo/main.mm)
  set_target_properties(CocoaTerminalDemo PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalDemo PRIVATE CocoaTerminal::CocoaTerminal)
endif()

if(COCOATERMINAL_BUILD_TESTS)
  enable_testing()
  add_executable(CocoaTerminalCoreTests tests/COTTerminalGridTests.cpp src/COTTerminalGrid.cpp)
  target_include_directories(CocoaTerminalCoreTests PRIVATE src ${VTERM_INCLUDE_DIRS})
  target_link_directories(CocoaTerminalCoreTests PRIVATE ${VTERM_LIBRARY_DIRS})
  target_link_libraries(CocoaTerminalCoreTests PRIVATE ${VTERM_LIBRARIES})
  target_compile_features(CocoaTerminalCoreTests PRIVATE cxx_std_17)
  add_test(NAME CocoaTerminalCoreTests COMMAND CocoaTerminalCoreTests)

  add_executable(CocoaTerminalThemeTests tests/COTTerminalThemeTests.mm)
  set_target_properties(CocoaTerminalThemeTests PROPERTIES LINKER_LANGUAGE OBJCXX)
  target_link_libraries(CocoaTerminalThemeTests PRIVATE CocoaTerminal::CocoaTerminal)
  add_test(NAME CocoaTerminalThemeTests COMMAND CocoaTerminalThemeTests)
endif()
