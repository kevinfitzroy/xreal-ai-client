// Package singboxbridge 是官方 sing-box 的极薄 gomobile 封装(替代 xray-bridge,见 SPEC.md §5.1)。
//
// 为什么换 sing-box:真机反馈 vless+Reality(xtls-rprx-vision)经 xray-core(gomobile)隧道
// 连上即停;同节点同协议用桌面 sing-box(v2rayN core)很稳 → 复刻桌面那套已验证可用的实现。见 issue #46。
//
// 设计原则(同 xray-bridge):
//   - Go 侧零业务逻辑:vmess://、vless:// 解析与 sing-box JSON 生成全在 Swift,这里只把一段
//     完整 sing-box JSON 喂给官方 box.New,起一个本地 127.0.0.1 direct inbound
//     (route-action override 到服务端 127.0.0.1:22 —— 1.13 已移除 inbound 的 override 字段)。
//   - go.mod 唯一直接依赖 = 官方 github.com/sagernet/sing-box。
//   - 不依赖 VpnService / TUN:只跑本地 inbound,app 侧把自己的 SSH socket 接到本地端口。
//   - 按 key 管理多实例:每条 tunnel 一个本地端口,互不干扰。
//
// gomobile bind 后,Swift 侧 dlsym 调用面(C 符号 Singboxbridge*):
//   SingboxbridgeStart(key, configJson)  // 抛 NSError 即启动失败
//   SingboxbridgeStop(key)
//   SingboxbridgeRunning(key)            // bool
//   SingboxbridgeVersion()               // sing-box 版本(冒烟测试)
package singboxbridge

import (
	"context"
	"sync"

	box "github.com/sagernet/sing-box"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

var (
	mu        sync.Mutex
	instances = map[string]*box.Box{}
)

// newContext 建一个带全部 inbound/outbound/endpoint/dns/service registry 的 context
// (官方 cmd/sing-box 同款:include.Context)。我们的配置只用当前(非弃用)字段,故无需注入
// deprecated.Manager;若将来配置里出现弃用字段,需按官方 cmd.go 再 service.ContextWith 包一层。
func newContext() context.Context {
	return include.Context(context.Background())
}

// Start 用一段完整 sing-box JSON 启动名为 key 的实例(应含 listen=127.0.0.1 的 direct inbound +
// route override + vless/vmess outbound)。幂等:同 key 已在跑则直接返回 nil(不重起)。
// 返回非 nil error → gomobile 在 Swift 侧抛 NSError,调用方据此判定「该 host 代理不可用 → 连接失败」。
func Start(key, configJSON string) error {
	mu.Lock()
	defer mu.Unlock()
	if instances[key] != nil {
		return nil
	}
	ctx := newContext()
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		return err
	}
	inst, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return err
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
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

// Version 返回 sing-box 版本字符串(build/冒烟测试用:能调通即证明 framework 链接成功)。
// C.Version 由 build ldflags 注入;gomobile bind 不带时为空 → 回退占位串。
func Version() string {
	if C.Version != "" {
		return C.Version
	}
	return "sing-box (embedded)"
}
