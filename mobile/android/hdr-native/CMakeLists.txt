# Fork: native decoder for the monochrome HEVC gain map tiles of iPhone HEIC photos (see ../../FORK.md).
cmake_minimum_required(VERSION 3.22.1)
project(hdr_native CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

file(GLOB DE265_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/third_party/libde265/libde265/*.cc)

add_library(hdr_native SHARED hdr_native.cc ${DE265_SOURCES})
target_include_directories(hdr_native PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/libde265)
target_compile_definitions(hdr_native PRIVATE HAVE_POSIX_MEMALIGN HAVE_MALLOC_H LIBDE265_STATIC_BUILD)
target_compile_options(hdr_native PRIVATE -O2 -fvisibility=hidden -Wno-unused-parameter -Wno-deprecated-declarations)
target_link_options(hdr_native PRIVATE -Wl,--gc-sections -Wl,-z,max-page-size=16384)
target_link_libraries(hdr_native PRIVATE log)
