module github.com/kevinfitzroy/xrealclient/xraybridge

go 1.23

// 唯一外部依赖在 `go mod tidy` 时由 build.sh 注入(go get github.com/xtls/xray-core@latest)。
// 锁定版本后此处会出现 require github.com/xtls/xray-core vX.Y.Z + 一长串间接依赖(都是 xray-core 自带,
// 不是我们额外引入的)。提交 go.mod + go.sum 以锁定可复现构建。
