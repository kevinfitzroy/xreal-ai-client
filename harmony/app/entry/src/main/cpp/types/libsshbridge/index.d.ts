// libsshbridge.so 的 ArkTS 类型契约(路径 A)。napi_init.cpp 的导出名必须与此对齐。
// 启用后 ArkTS 侧 `import nativeBridge from 'libsshbridge.so'` 即得此形状(见 NativeSshChannel.ets)。

export const connect: (host: string, port: number, user: string, privateKeyPem: string, viaHandle: number) => Promise<number>;
export const openShell: (sessionHandle: number, cols: number, rows: number, startup: string) => Promise<number>;
export const readChannel: (channelHandle: number) => Promise<ArrayBuffer>;
export const writeChannel: (channelHandle: number, data: ArrayBuffer) => void;
export const resizePty: (channelHandle: number, cols: number, rows: number) => void;
export const exec: (sessionHandle: number, command: string) => Promise<string>;
export const closeChannel: (channelHandle: number) => void;
export const closeSession: (sessionHandle: number) => void;
