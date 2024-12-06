cmake_minimum_required(VERSION 3.22.1)
set(CMAKE_VERBOSE_MAKEFILE on)

project("aztest")

find_library(ANDROID_LIB android)
find_library(LOG_LIB log)
find_library(GLESV3_LIB GLESv3)

find_path(INCLUDE_DIR stdlib.h)
find_file(CRT1_PATH libc.so)
get_filename_component(CRT1_PATH ${CRT1_PATH} DIRECTORY)

set(APP_DIR "${CMAKE_SOURCE_DIR}/../../../../../../blockeditor")
set(LIBZIGPART_PATH "${APP_DIR}/zig-out/lib/libzigpart.so")

add_custom_command(
        OUTPUT ${LIBZIGPART_PATH}
        OUTPUT ${APP_DIR}/zig-out/lib/_force_rerun_every_time # cmake can't track zig deps properly. zig caches so it shouldn't slow down the build too much.
        COMMAND zig build -Dplatform=android -DINCLUDE_DIR=${INCLUDE_DIR} -DCRT1_PATH=${CRT1_PATH} -DCMAKE_ANDROID_ARCH_ABI=${CMAKE_ANDROID_ARCH_ABI} -DANDROID_LIB=${ANDROID_LIB} -DANDROID_PLATFORM=${ANDROID_PLATFORM} -DLOG_LIB=${LOG_LIB} -DGLESV3_LIB=${GLESV3_LIB}
        WORKING_DIRECTORY ${APP_DIR}
        COMMENT "Generating libzigpart.so"
        VERBATIM
)
add_custom_target(generate_libzigpart ALL DEPENDS ${LIBZIGPART_PATH})

add_library(${CMAKE_PROJECT_NAME} SHARED
        native-lib.cpp)

add_dependencies(${CMAKE_PROJECT_NAME} generate_libzigpart)

target_link_libraries(${CMAKE_PROJECT_NAME}
        ${ANDROID_LIB}
        ${LOG_LIB}
        ${GLESV3_LIB}
        ${LIBZIGPART_PATH})