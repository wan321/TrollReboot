#import <Foundation/Foundation.h>

/*
 * v3.5-mon：充电卡死自动重启。
 *
 * 设计（按用户要求收紧）：
 *   - 联合条件全部写死在程序里，界面不提供配置项。
 *   - 唯一对外可调的是「连续多少分钟算卡死」，传一个数字进来。
 *   - 安全状态落盘，重启后仍然有效。
 *   - 「没插充电器绝不执行」是硬条件，任何输入都改不了。
 */

/// 唯一可配置项的范围
#define TRMON_MINUTES_MIN 1
#define TRMON_MINUTES_MAX 60
#define TRMON_MINUTES_DEFAULT 5

/// 写死的联合条件
#define TRMON_CURRENT_MA 50     // |电流| < 50mA 才算没在充
#define TRMON_TEMP_MIN_C 0      // 温度下限（℃）
#define TRMON_TEMP_MAX_C 45     // 温度上限（℃）
#define TRMON_SAMPLE_SEC 10     // 采样间隔（秒）

/// 写死的安全约束
#define TRMON_COOLDOWN_SEC (15 * 60)   // 两次重启之间至少 15 分钟
#define TRMON_MAX_PER_HOUR 3           // 每小时最多 3 次
#define TRMON_MAX_PER_DAY 8            // 24 小时最多 8 次
#define TRMON_MAX_PER_BOOT 3           // 一次开机最多 3 次（与熔断阈值一致）
#define TRMON_BREAKER_COUNT 3          // 连续 3 次自动重启后条件仍在 → 判故障，停止自动重启
#define TRMON_GRACE_SEC 60             // 电流短暂恢复的容忍窗口（秒），超过才清零

/// 配置文件路径（只有 root 守护写得到）；里面只存一个数字
NSString *TRMonitorConfigPath(void);
NSString *TRMonitorStatePath(void);

/// 读「连续多少分钟算卡死」（读不到/越界返回默认 5）
NSInteger TRMonitorStuckMinutes(void);

/// 写「连续多少分钟算卡死」（原子写 + fsync）
BOOL TRMonitorWriteStuckMinutes(NSInteger minutes, NSString **detail);

/// 读/写安全状态（lastRebootTS / bootTS / rebootCountBoot / breaker / rebootTimes）
NSDictionary *TRMonitorStateLoad(void);
BOOL TRMonitorStateWrite(NSDictionary *state);

/// 单次采样是否满足全部联合条件；不满足时 reason 说明原因（只判断，不动手）
/// softOnly：只有「电流恢复」这一条不满足（其它硬条件都满足）时为 YES，调用方应走容忍窗口而不是立即清零
BOOL TRMonitorSampleIsStuck(NSDictionary *sample, NSString **reason, BOOL *softOnly);

/// 现在能不能真的重启；不能时返回原因，能返回 nil
NSString *TRMonitorSafetyBlock(NSDictionary *state);

/// 联合条件的一行文本（面板/日志用）
NSString *TRMonitorConditionsText(void);

/// App 沙盒内读不到配置文件，用守护告知的值覆盖（仅本进程有效）
void TRMonitorSetCachedMinutes(NSInteger minutes);

/// 当前这次开机的 kern.boottime（秒），失败返回 0
double TRMonitorCurrentBootTime(void);
