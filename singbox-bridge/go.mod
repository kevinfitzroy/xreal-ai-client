module github.com/kevinfitzroy/xrealclient/singboxbridge

// sing-box v1.13.x 需要 go 1.24.x(其 go.mod: go 1.24.7);本机 go1.25 满足,无需升级。
// 升级 sing-box 时改下面 require 再 `go mod tidy`(build-ios.sh 会在缺 go.sum 时自动 tidy)。
go 1.24.7

require github.com/sagernet/sing-box v1.13.13

// 其余 require(sing-box + sing + gvisor/utls/quic 等间接依赖)由 `go mod tidy` 在首次
// build 时解析并写入 go.sum —— 因 Claude 环境无网络,这里只 pin 直接依赖,go.sum 由你本机生成后提交。
