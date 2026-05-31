// 路径 A:libssh2 的 NAPI 薄封装(骨架)。对齐 Android sshj 的能力面:
//   connect(handshake+pubkey auth) / openShell(pty+shell) / readChannel / writeChannel /
//   resizePty / exec / closeChannel / closeSession,外加 via 的 direct-tcpip(多跳)。
//
// 本文件是**结构骨架** —— NAPI 注册 + 函数签名 + libssh2 调用点注释齐全;真正可跑需:
//   1. 交叉编译 libssh2(+OpenSSL/mbedTLS)成 HarmonyOS arm64 静态库
//   2. 把阻塞式 libssh2 调用包进 napi async work(libuv 线程池),不阻塞 ArkTS 主线程
//   3. 用整数句柄表(handle→LIBSSH2_SESSION*/CHANNEL*)做 ArkTS↔native 对象映射
// 详见 docs/ssh-options.md §A 完成清单。

#include "napi/native_api.h"
// #include <libssh2.h>          // ← 交叉编译好头文件后取消注释
#include <string>
#include <map>
#include <mutex>

// ───────────────────────────────────────────────────────────────────────────
// 句柄表:ArkTS 侧只见整数句柄,native 侧映射到 libssh2 对象 + socket fd。
// ───────────────────────────────────────────────────────────────────────────
struct SshSession {
    int sockfd = -1;
    // LIBSSH2_SESSION* session = nullptr;
};
struct SshChannel {
    int sessionHandle = 0;
    // LIBSSH2_CHANNEL* channel = nullptr;
};
static std::mutex g_mu;
static std::map<int, SshSession*> g_sessions;
static std::map<int, SshChannel*> g_channels;
static int g_nextHandle = 1;

// ───────────────────────────────────────────────────────────────────────────
// connect(host, port, user, privateKeyPem, viaHandle) -> Promise<number sessionHandle>
//   libssh2_session_init → (socket connect 或经 viaHandle 的 direct_tcpip)→
//   libssh2_session_handshake → host key TOFU 校验 →
//   libssh2_userauth_publickey_frommemory(ed25519 PEM)→ 返回句柄
// ───────────────────────────────────────────────────────────────────────────
static napi_value Connect(napi_env env, napi_callback_info info) {
    // TODO: 解析 5 个入参;若 viaHandle>0,在该 session 上 libssh2_channel_direct_tcpip_ex(目标 host:port)
    //       拿到隧道 socket,再在其上 handshake(= ProxyJump)。否则普通 socket connect。
    //       全程包 napi_create_async_work,在 worker 线程跑阻塞调用,complete 回调 resolve Promise。
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

// openShell(sessionHandle, cols, rows, startup) -> Promise<number channelHandle>
//   libssh2_channel_open_session → libssh2_channel_request_pty_ex("xterm-256color", cols, rows)
//   → libssh2_channel_process_startup("exec", startup)(或 shell)
static napi_value OpenShell(napi_env env, napi_callback_info info) {
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

// readChannel(channelHandle) -> Promise<ArrayBuffer>
//   非阻塞 libssh2_channel_read;无数据时短 poll;EOF(libssh2_channel_eof)回空 ArrayBuffer。
static napi_value ReadChannel(napi_env env, napi_callback_info info) {
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

// writeChannel(channelHandle, ArrayBuffer) -> void   libssh2_channel_write
static napi_value WriteChannel(napi_env env, napi_callback_info info) {
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

// resizePty(channelHandle, cols, rows) -> void        libssh2_channel_request_pty_size_ex
static napi_value ResizePty(napi_env env, napi_callback_info info) {
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

// exec(sessionHandle, command) -> Promise<string>     open_session + channel_exec + 读到 EOF
static napi_value Exec(napi_env env, napi_callback_info info) {
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

static napi_value CloseChannel(napi_env env, napi_callback_info info) {
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}
static napi_value CloseSession(napi_env env, napi_callback_info info) {
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

// ───────────────────────────────────────────────────────────────────────────
// NAPI 模块注册:导出名要与 types/libsshbridge/index.d.ts 对齐。
// ───────────────────────────────────────────────────────────────────────────
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "connect",      nullptr, Connect,      nullptr, nullptr, nullptr, napi_default, nullptr },
        { "openShell",    nullptr, OpenShell,    nullptr, nullptr, nullptr, napi_default, nullptr },
        { "readChannel",  nullptr, ReadChannel,  nullptr, nullptr, nullptr, napi_default, nullptr },
        { "writeChannel", nullptr, WriteChannel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resizePty",    nullptr, ResizePty,    nullptr, nullptr, nullptr, napi_default, nullptr },
        { "exec",         nullptr, Exec,         nullptr, nullptr, nullptr, napi_default, nullptr },
        { "closeChannel", nullptr, CloseChannel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "closeSession", nullptr, CloseSession, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module sshModule = {
    .nm_version = 1, .nm_flags = 0, .nm_filename = nullptr,
    .nm_register_func = Init, .nm_modname = "sshbridge", .nm_priv = nullptr, .reserved = { 0 },
};
extern "C" __attribute__((constructor)) void RegisterSshModule(void) { napi_module_register(&sshModule); }
