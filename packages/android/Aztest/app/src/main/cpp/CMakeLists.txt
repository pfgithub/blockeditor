cmake_minimum_required(VERSION 3.22.1)

project("aztest")

find_library(ANDROID_LIB android)
find_library(LOG_LIB log)
find_library(GLESV3_LIB GLESv3)

find_path(STDLIB_H_PATH stdlib.h)
get_filename_component(INCLUDE_DIR ${STDLIB_H_PATH} DIRECTORY)

find_path(SYS_ERRNO_PATH sys/errno.h)
get_filename_component(SYS_INCLUDE_DIR ${SYS_ERRNO_PATH} DIRECTORY)
get_filename_component(SYS_INCLUDE_DIR ${SYS_INCLUDE_DIR} DIRECTORY)

find_file(CRT1_PATH crt1.o)

add_custom_command(
        OUTPUT ${CMAKE_SOURCE_DIR}/zig-out/lib/libzigpart.a
        COMMAND zig build -DINCLUDE_DIR=${INCLUDE_DIR} -DSYS_INCLUDE_DIR=${SYS_INCLUDE_DIR} -DCRT1_PATH=${CRT1_PATH} -DCMAKE_ANDROID_ARCH_ABI=${CMAKE_ANDROID_ARCH_ABI} -DANDROID_LIB=${ANDROID_LIB} -DLOG_LIB=${LOG_LIB} -DGLESV3_LIB=${GLESV3_LIB}
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Generating libzigpart.a"
        VERBATIM
)
add_custom_target(generate_liba ALL DEPENDS ${CMAKE_SOURCE_DIR}/zig-out/lib/libzigpart.a)

add_library(${CMAKE_PROJECT_NAME} SHARED
        native-lib.cpp)

add_dependencies(${CMAKE_PROJECT_NAME} generate_liba)

set(LIBA_PATH "${CMAKE_SOURCE_DIR}/zig-out/lib/libzigpart.a")

target_link_libraries(${CMAKE_PROJECT_NAME}
        ${ANDROID_LIB}
        ${LOG_LIB}
        ${GLESV3_LIB}
        ${LIBA_PATH})