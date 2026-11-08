# TrollReboot vs「电池助手 1.0.7」：逆向对比与落地结论（3.5-mon4-io4）

对比对象：`C:\Users\wan\Desktop\电池助手BatteryInfo_1.0.7.ipa`
（bundle `com.callassist.batteryinfolist`，1.0.7/7，arm64，minOS 14.0，SDK iphoneos15.2，ad-hoc 签名，无 FairPlay 加密，143,968 B）。
完整取证报告：`C:\ReverseEngineering\Samples\batteryinfo-1.0.7\REPORT.md`。

## 一、对方凭什么能读私有电池（关键证据）

entitlements 只有 6 条：

| key | value |
| --- | --- |
| `com.apple.private.security.no-sandbox` | true |
| `platform-application` | true |
| `com.apple.private.security.container-required` | false |
| `com.apple.private.persona-mgmt` | true |
| `com.apple.private.security.system-application` | true |
| `com.apple.security.iokit-user-client-class` | `IOSurfaceRootUserClient`, `AGXDeviceUserClient`, `IOPMPowerSourceClient` |

服务名只用 `IOPMPowerSource`（符号：`IOServiceMatching` / `IOServiceGetMatchingService` /
`IORegistryEntryCreateCFProperties` / `IOObjectRelease` / `kIOMasterPortDefault`，静态链接私有 IOKit）。

**结论**：App 进程读私有电池不需要越狱，也不需要 dlopen，钥匙就是
`iokit-user-client-class ⊇ IOPMPowerSourceClient` + `no-sandbox` + `system-application`。
`AppleSmartBattery` / `AppleARMPMUCharger` 是别的 IOUserClient 类，**没有对应授权**，
所以 TrollReboot mon9 之前「App 进程一读就崩」不是 `IOPMPowerSource` 的锅，是越权访问了这两类。

## 二、本次落到 TrollReboot 的改动

1. `TRBattery.m`：私有读取收敛到 `IOPMPowerSource` 单一服务
   —— `TRServiceNames = { "IOPMPowerSource" }`；`p`/`alt` 只取这一个字典；
   读不到时的诊断文案明确写「未尝试 AppleSmartBattery/AppleARMPMUCharger：无对应授权，试了会崩」。
2. `TRBattery.m`：字段口径对齐
   - `source` 显式标 `IOPMPowerSource`（面板「数据来源」据此显示）；
   - 新增私有 `serial`（对方也读 `Serial`，面板不展示，只用于确认读的是同一颗电池）；
   - `percent` 在 `CurrentCapacity` 缺失时用 `AppleRawCurrentCapacity / AppleRawMaxCapacity` 换算；
   - 健康度 = 满容量 / `DesignCapacity`，满容量按 `AppleRawMaxCapacity → MaxCapacity → NominalChargeCapacity`
     依次回退，并新增 `healthBasis` 说明用的是哪一档（去掉原来 >120% 时硬切 MaxCapacity 的隐式逻辑）。
3. `RootViewController.m`：「电池实时容量」在 `MaxCapacity` 缺失时回退 `AppleRawMaxCapacity`；
   构建标记升到 `TrollReboot 3.5-mon4-io4`（**版本号仍 3.5，未升，等用户拍板**）。
4. `.github/workflows/build.yml`：新增回归断言——二进制里若再出现
   `AppleSmartBattery` / `AppleARMPMUCharger` 直接失败；`IOPMPowerSource`、`healthBasis` 必须在。

## 三、对比到了但这次**没有**抄的部分（及理由）

| 对方做法 | 是否采用 | 理由 |
| --- | --- | --- |
| `UIBackgroundModes=audio` + `AVAudioSessionCategoryPlayback` 循环 `BGSound.wav` 保活 | 不采用 | TrollReboot 的监控在 root 守护进程里（fork 隔离 + 心跳），GUI 被挂起不影响巡检与重启；加后台音频只换来耗电和「偷偷放音」 |
| `AVPictureInPictureController` 播 `playBG.mp4` 占画中画位 | 不采用 | 同上，是给只能在 App 内跑逻辑的 App 用的保活技巧 |
| 自绘悬浮窗（`BatteryTextView`：双击缩放、贴边隐藏、拖拽） | 暂不采用 | TrollReboot 现有仪表盘已按参考 App 复刻字段；悬浮窗是产品形态差异，不做进来 |
| `libMobileGestalt` 取机型/序列号（`ZSDeviceTypeInfo`） | 不采用（已有等价） | 面板已用 `uname` + `sysctl hw.machine` 得到机型字符串，够用 |
| 用 `getifaddrs` 差分算上下行网速 | 不采用 | 与重启/监控无关 |
| `storage.AppBundles` 等权限对方没有 | 保留我们的 | 我们的权限集合是「读电池 6 条 + 装开机启动器所需」的超集；读电池只依赖那 6 条里的 4 条，互不冲突 |

## 四、仍未验证（需要真机）

- 树莓派式结论（Windows 上 REA 不解析 Mach-O）不影响本次改动，但**改动本身没在真机上跑过**：
  待验证项 = 面板「数据来源」是否显示 `私有 IOKit/IOPMPowerSource`、「读取诊断」三段是否 link 成功、
  健康度是否与设置里「最大容量」对得上。
- 若 link 仍失败，下一步按「电池助手」逐条对齐补：`SYS_` 类信息不需要，重点是确认
  `ldid -e` 回读里 `iokit-user-client-class` 真的带上了 `IOPMPowerSourceClient`（CI 已有逐条校验）。
