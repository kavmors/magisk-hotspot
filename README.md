# Magisk Hotspot

这是一个适用于 Android 10 及以上版本的 Magisk 模块。配置 SSID 后，它会在系统
启动完成后开启 Wi-Fi 热点，并可向实际的热点网络接口添加一个稳定 IPv4 地址。
它还可为热点客户端提供本地域名。热点接口被 Android 重新创建后，守护进程会
按配置恢复地址和 DNS 服务。

模块通过 Android 的网络共享 API 启动热点，因此正常情况下由系统继续管理 DHCP
和上游网络；如果厂商 ROM 拒绝该 API，模块会回退到 AOSP 的 SoftAP shell 命令，
并在日志中记录结果。

## 配置

安装前可编辑压缩包根目录的 `config.yml`。安装后配置路径为：

```text
/data/adb/modules/magisk-hotspot/config.yml
```

默认配置：

```yaml
hotspot:
  ssid: ""
  password: ""
  band: "auto"         # 2.4GHz、5GHz 或 auto

network:
  ip_address: ""

dns:
  domain: ""

behavior:
  boot_delay_seconds: 15
  keep_alive: true
  retry_interval_seconds: 10
```

- `ssid`：最多 32 个字符。为空时不启动热点，守护进程每 3 秒重读一次配置，填写后
  自动启动热点。
- `password`：为空时创建开放热点；非空时使用 WPA2，密码必须为 8 到 63 个字符。
- `band`：`2.4GHz`、`5GHz` 或 `auto`。5 GHz 是否可用取决于硬件、国家码和厂商 ROM。
- `ip_address`：为空时不向热点接口添加地址，保留 Android 的 DHCP 子网；非空时
  必须是私网 IPv4 `/32` CIDR。
- `domain`：为空时不启动 DNS 服务。非空时，该域名的 A 记录会解析到
  `network.ip_address`；如果地址为空，则解析到 Android 分配给热点接口的 IPv4
  地址。域名不区分大小写，最多 253 个字符。推荐使用 `home.arpa` 后缀，避免
  `.local` 被客户端当作 mDNS 名称处理。
- `keep_alive`：为 `true` 时，热点连续三次不可用会被重新启动；为 `false` 时只在
  开机和配置变更时启动。

字符串应使用成对的单引号或双引号。此模块只解析示例所示的简单 YAML 标量，
不支持数组、锚点、多行字符串或转义序列。

修改安装后的配置会自动触发重新应用；也可在 Magisk 中点击模块的“操作”按钮。
SSID、密码或频段变化会短暂重启热点并断开现有客户端。

热点就绪后，Magisk 模块列表中的描述会显示当前地址，例如 `IP: 192.168.43.1`。
启用 DNS 时还会追加域名，例如 `IP: 192.168.43.1 | DNS: router.home.arpa`。
热点未运行时显示 `Hotspot inactive`。

DNS 服务会接管从热点接口发出的传统 UDP/TCP 53 查询。配置域名由模块直接回答，
其他域名转发到 Android 当前活动上游网络的 DNS 服务器。启用了“私人 DNS”、DoH
或其他加密 DNS 且不回退到系统 DNS 的客户端不会经过此服务。

## 构建和安装

构建机需要 Android SDK Platform 29、Android Build Tools 和 JDK 8 或更高版本：

```sh
./build.sh
```

产物位于 `dist/magisk-hotspot-v1.0.0.zip`。在 Magisk 应用的“从本地安装”中选择该
ZIP，然后重启。升级安装会保留设备上已有的 `config.yml`。

仓库中的 `bin/hotspotctl.dex` 是已构建的辅助程序；`tools/build-hotspotctl.sh`
可以从源码重新生成它。

## 运行与排错

日志位于：

```text
/data/adb/magisk-hotspot/hotspot.log
```

常用检查命令：

```sh
su -c 'cat /data/adb/magisk-hotspot/hotspot.log'
su -c 'ip -4 address show'
su -c 'dumpsys wifi | grep -i -A 8 softap'
su -c 'cat /data/adb/magisk-hotspot/dns-server.log'
```

如果 5 GHz 启动失败，先改用 `2.4GHz`。不同厂商可能修改或限制热点系统 API；此时
日志会包含 Java 异常和 shell 回退结果，可据此确认 ROM 的具体限制。

## 网络与安全

模块为配置的地址添加一个仅匹配热点入口和目标地址的 IPv4 `INPUT` 放行规则，
从而让热点客户端能访问本机监听的服务；并仅在热点入口重定向 DNS 流量。它不会
启动 HTTP、SSH 或其他应用服务；客户端能否连接某个端口，仍取决于本机是否有
服务在该地址或 `0.0.0.0` 上监听。

使用空密码会创建任何附近设备都可加入的开放热点，请仅在可信环境中使用。模块
添加的防火墙规则允许热点客户端访问本机服务。卸载模块会终止守护进程、移除附加
地址和防火墙规则，但不会强制关闭用户可能仍在使用的系统热点。
