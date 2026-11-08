#import <Foundation/Foundation.h>

/*
 * v3.5-probe 只读电池探针。
 *
 * 目的：在真机上验证私有 IOKit（IOPMPowerSource）能否读到
 *   - 外部电源：ExternalConnected
 *   - 是否在充：IsCharging / FullyCharged
 *   - 电流（mA）：InstantAmperage / Amperage
 *   - 电压（mV）：Voltage
 *   - 温度（0.1℃）：Temperature
 *   - 电量：CurrentCapacity / AppleRawCurrentCapacity / AppleRawMaxCapacity
 *
 * 本文件不做任何写操作、不发任何重启命令。只读。
 */

/// 读一次电池信息。失败时 dict[@"ok"] = @NO，dict[@"error"] 为原因字符串。
NSDictionary *TRBatteryRead(void);

/// 把一次采样格式化成一行紧凑文本（用于探针面板与日志）。
NSString *TRBatteryLine(NSDictionary *sample);

/// 当前是否"看起来该触发"（插电 + 在充 + 未满 + |电流| < 阈值）。仅用于显示提示，不执行任何动作。
BOOL TRBatteryLooksStuck(NSDictionary *sample, int currentThresholdMA);

/// 把一次采样按「监控预览」逐条判读，返回一行文本（只判断，不执行任何动作）。
NSString *TRMonitorVerdict(NSDictionary *sample);

/// 探针日志路径（App Documents/charge-probe.log）
NSString *TRProbeLogPath(void);

/// 追加一行到探针日志（带时间戳，立即 fsync）。
void TRProbeLogAppend(NSString *line);
