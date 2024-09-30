cmake_minimum_required(VERSION 3.22.1)
set(CMAKE_VERBOSE_MAKEFILE on)

project("aztest")

find_library(ANDROID_LIB android)
find_library(LOG_LIB log)
find_library(GLESV3_LIB GLESv3)

find_path(INCLUDE_DIR stdlib.h)
find_file(CRT1_PATH libc.so)
get_filename_component(CRT1_PATH ${CRT1_PATH} DIRECTORY)

add_custom_command(
        OUTPUT ${CMAKE_SOURCE_DIR}/zig-out/lib/libzigpart.a
        OUTPUT ${CMAKE_SOURCE_DIR}/zig-out/lib/_force_rerun_every_time # cmake can't track zig deps properly. zig caches so it shouldn't slow down the build too much.
        COMMAND zig build -DINCLUDE_DIR=${INCLUDE_DIR} -DCRT1_PATH=${CRT1_PATH} -DCMAKE_ANDROID_ARCH_ABI=${CMAKE_ANDROID_ARCH_ABI} -DANDROID_LIB=${ANDROID_LIB} -DLOG_LIB=${LOG_LIB} -DGLESV3_LIB=${GLESV3_LIB}
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Generating libzigpart.a"
        VERBATIM
)
add_custom_target(generate_liba ALL DEPENDS ${CMAKE_SOURCE_DIR}/zig-out/lib/libzigpart.a)

add_library(${CMAKE_PROJECT_NAME} SHARED
        native-lib.cpp)

add_dependencies(${CMAKE_PROJECT_NAME} generate_liba)

set(LIBA_PATH "${CMAKE_SOURCE_DIR}/zig-out/lib/libzigpart.so")

target_link_libraries(${CMAKE_PROJECT_NAME}
        ${ANDROID_LIB}
        ${LOG_LIB}
        ${GLESV3_LIB}
        ${LIBA_PATH})