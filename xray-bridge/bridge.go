// Package xraybridge 是官方 xray-core 的极薄 gomobile 封装。
//
// 设计原则(对应 SSH-over-443 隧道功能,见仓库 SPEC.md §5.1):
//   - Go 侧零业务逻辑:vmess:// 解析、xray JSON 配置生成全在 Kotlin/Swift,这里只把一段
//     完整的 xray JSON 配置喂给官方 core.StartInstance,通常起一个本地 127.0.0.1
//     dokodemo-door inbound(override 到服务端 127.0.0.1:22)。
//   - go.mod 唯一外部依赖 = 官方 github.com/xtls/xray-core,不引入 libXray / AndroidLibXrayLite。
//   - 不依赖 VpnService / TUN:只跑本地 inbound,app 侧把自己的 SSH socket 接到本地端口。
//   - 按 key 管理多实例:每条 tunnel 一个本地端口,互不干扰。
//
// gomobile bind 后,Kotlin 侧调用面(class xraybridge.Xraybridge):
//   Xraybridge.start(key, configJson)  // 抛 Exception 即启动失败
//   Xraybridge.stop(key)
//   Xraybridge.running(key)            // boolean
//   Xraybridge.version()               // xray-core 版本(冒烟测试)
package xraybridge

import (
	"sync"

	"github.com/xtls/xray-core/core"
	// 注册所有 protocol / transport / json 配置加载器(官方 main 包同款 import)。都在 xray-core
	// module 内,不增加外部依赖,只影响 AAR 体积。需瘦身时可改成只 import vmess/outbound +
	// socks/inbound + tls + freedom + json 配置加载器。
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu        sync.Mutex
	instances = map[string]*core.Instance{}
)

// Start 用一段完整 xray JSON 配置启动名为 key 的实例(应含 listen=127.0.0.1 的 inbound +
// vmess(+tls) outbound)。幂等:同 key 已在跑则直接返回 nil(不重起)。
// 返回非 nil error → gomobile 在 Kotlin 侧抛 Exception,调用方据此判定"该 host 代理不可用 → 连接失败"。
func Start(key, configJSON string) error {
	mu.Lock()
	defer mu.Unlock()
	if instances[key] != nil {
		return nil
	}
	inst, err := core.StartInstance("json", []byte(configJSON))
	if err != nil {
		return err
	}
	instances[key] = inst
	return nil
}

// Stop 关闭名为 key 的实例(幂等)。
func Stop(key string) error {
	mu.Lock()
	defer mu.Unlock()
	inst := instances[key]
	if inst == nil {
		return nil
	}
	delete(instances, key)
	return inst.Close()
}

// Running 报告名为 key 的实例是否在跑。
func Running(key string) bool {
	mu.Lock()
	defer mu.Unlock()
	return instances[key] != nil
}

// Version 返回 xray-core 版本字符串(build/冒烟测试用:能调通即证明 AAR 链接成功)。
func Version() string {
	return core.Version()
}
