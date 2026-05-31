# NAPI native 构建(路径 A:libssh2 + 薄封装)。默认未接入主构建
# (entry/build-profile.json5 的 externalNativeOptions 注释着)→ 选定路径 A 后再开。
#
# 前置:交叉编译 libssh2(+ OpenSSL 或 mbedTLS)成 HarmonyOS arm64 静态库,放 ./libs/arm64-v8a/。
#       推荐用 OpenHarmony-SIG/tpc_c_cplusplus(Lycium)交叉编译框架。见 docs/ssh-options.md §A。

cmake_minimum_required(VERSION 3.16)
project(xrealssh)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVE_ROOT}/include)   # libssh2.h 等头文件放 ./include/

add_library(sshbridge SHARED napi_init.cpp)

# 预编译的 libssh2 + 加密后端(交叉编译产物)
add_library(ssh2 STATIC IMPORTED)
set_target_properties(ssh2 PROPERTIES IMPORTED_LOCATION ${NATIVE_ROOT}/libs/${OHOS_ARCH}/libssh2.a)
add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES IMPORTED_LOCATION ${NATIVE_ROOT}/libs/${OHOS_ARCH}/libcrypto.a)

target_link_libraries(sshbridge PUBLIC
    libace_napi.z.so      # NAPI
    ssh2
    crypto
    libhilog_ndk.z.so)    # native 日志
