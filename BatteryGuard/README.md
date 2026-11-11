# BatteryGuard.dylib

注入「电池助手 1.0.7」的附加层，只做三件事：读电池 → 判充电卡死 → 调 TrollStore helper 重启。
App 原有代码不改，原有电池/机型信息读取完全保留。

## 为什么不用 Theos

Theos 的 tweak 目标默认按「插件」打包和链接（还要引 ../ 目录下的源文件），在 CI 上多一层不确定；
这个 dylib 只依赖 UIKit/Foundation/IOKit，直接用 clang 生成 `.dylib` 更可控：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -arch arm64 -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 \
  -framework UIKit -framework Foundation -framework IOKit \
  -Wl,-install_name,@executable_path/BatteryGuard.dylib \
  -I.. -o BatteryGuard.dylib \
  BGMain.m ../TRBattery.m ../TRMonitor.m ../TRRootOps.m
```

## 注入

```
insert_dylib --strip-codesig --overwrite "@executable_path/BatteryGuard.dylib" <可执行> <可执行>.tmp
ldid -e <原可执行> > ent.plist
ldid -S'ent.plist' <注入后可执行>
ldid -S BatteryGuard.dylib
```

## 运行时状态

- 日志：`/var/mobile/Library/Caches/com.wan.batterychargeguard/guard.log`
- 分钟配置：同目录 `monitor.conf`（`{"stuckMinutes":5}`）
- 安全状态：同目录 `monitor.state`（与 TrollReboot 的 com.wan.trollreboot 互不干扰，
  靠 `TRMonitorSetDirectory()` 切换目录）

## 条件（与 TrollReboot 完全一致，写死）

插电 + 系统在充 + |电流|<50mA + 电量<100% + 未满容量 + 温度 0–45℃ + 持续 N 分钟；
拔电立即清零，电流短暂恢复容忍 60 秒；冷却 15 分钟、每小时 3 次、每天 8 次、每次开机 3 次、
连续 3 次后熔断停止，恢复正常充电时熔断归零。

## 1.6：熔断可自愈 / 可人工重置

1.5 只有「连续 3 次 → 熔断停止」这一半，另一半（恢复后归零、人工重置）漏了实现，
状态文件里的 `breaker` 只增不减，一旦到 3 就永久卡在「需人工重置」。1.6 补齐：

- **自动归零**：插电且条件恢复正常（不卡死、无容忍窗口）时，`breaker` 清 0（保留冷却与次数限制，
  防止「一恢复就把频率闸门也清零」）；面板与 guard.log 会记一行。
- **人工重置**：面板顶部新增橙色「重置」按钮；HTTP `GET http://127.0.0.1:8899/monitor/reset`
  一次清掉 `breaker / lastRebootTS / rebootCountBoot / rebootTimes / bootTS`。
- **状态查询**：`GET http://127.0.0.1:8899/monitor` 返回 `breaker / breakerMax / minutes / safety`。
- 守护进程路径（bgreqd）补上 `breaker` 累计（1.5 只有 App 内路径会加）与同样的自动归零、
  同样的 `/monitor/reset` 路由。

状态文件位置（两处，互不相干）：
`/var/mobile/Library/Caches/com.wan.batterychargeguard/monitor.state`（本注入版）
与 `/var/mobile/Library/Caches/com.wan.trollreboot/monitor.state`（TrollReboot 本体）。
TrollReboot 的 `/monitor/reset` 清的是它自己那份，**不会**解开 BatteryGuard 的熔断。
