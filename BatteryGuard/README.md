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
