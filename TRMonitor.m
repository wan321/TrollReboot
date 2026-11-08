#import "TRMonitor.h"

#import <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

static NSString *const TRMonDir = @"/var/mobile/Library/Caches/com.wan.trollreboot";
static NSString *const TRMonMinutesKey = @"stuckMinutes";

NSString *TRMonitorConfigPath(void)
{
	return [TRMonDir stringByAppendingPathComponent:@"monitor.conf"];
}

NSString *TRMonitorStatePath(void)
{
	return [TRMonDir stringByAppendingPathComponent:@"monitor.state"];
}

static NSDictionary *TRReadJSON(NSString *path)
{
	NSData *d = [NSData dataWithContentsOfFile:path];
	if (d.length == 0)
		return nil;
	id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
	return [o isKindOfClass:[NSDictionary class]] ? (NSDictionary *)o : nil;
}

static BOOL TRWriteJSON(NSString *path, NSDictionary *obj, NSString **detail)
{
	NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
	if (d.length == 0)
	{
		if (detail)
			*detail = @"编码失败";
		return NO;
	}

	[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
	                         withIntermediateDirectories:YES
	                                          attributes:nil
	                                               error:NULL];

	int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
	{
		if (detail)
			*detail = [NSString stringWithFormat:@"open errno=%d", errno];
		return NO;
	}

	const uint8_t *p = d.bytes;
	size_t left = d.length;
	while (left > 0)
	{
		ssize_t n = write(fd, p, left);
		if (n <= 0)
		{
			int e = errno;
			close(fd);
			if (detail)
				*detail = [NSString stringWithFormat:@"write errno=%d", e];
			return NO;
		}
		p += n;
		left -= (size_t)n;
	}
	fsync(fd);
	close(fd);

	if (detail)
		*detail = @"ok";
	return YES;
}

static NSInteger gCachedMinutes = 0;

void TRMonitorSetCachedMinutes(NSInteger minutes)
{
	if (minutes < TRMON_MINUTES_MIN)
		minutes = TRMON_MINUTES_MIN;
	if (minutes > TRMON_MINUTES_MAX)
		minutes = TRMON_MINUTES_MAX;
	gCachedMinutes = minutes;
}

NSInteger TRMonitorStuckMinutes(void)
{
	if (gCachedMinutes > 0)
		return gCachedMinutes;

	NSDictionary *cfg = TRReadJSON(TRMonitorConfigPath());
	NSInteger m = TRMON_MINUTES_DEFAULT;
	if ([cfg[TRMonMinutesKey] isKindOfClass:[NSNumber class]])
		m = [cfg[TRMonMinutesKey] integerValue];
	if (m < TRMON_MINUTES_MIN)
		m = TRMON_MINUTES_MIN;
	if (m > TRMON_MINUTES_MAX)
		m = TRMON_MINUTES_MAX;
	return m;
}

BOOL TRMonitorWriteStuckMinutes(NSInteger minutes, NSString **detail)
{
	if (minutes < TRMON_MINUTES_MIN)
		minutes = TRMON_MINUTES_MIN;
	if (minutes > TRMON_MINUTES_MAX)
		minutes = TRMON_MINUTES_MAX;

	return TRWriteJSON(TRMonitorConfigPath(), @{ TRMonMinutesKey : @(minutes) }, detail);
}

NSDictionary *TRMonitorStateLoad(void)
{
	NSDictionary *raw = TRReadJSON(TRMonitorStatePath());
	if (raw == nil)
		return @{};

	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	out[@"lastRebootTS"] = @([raw[@"lastRebootTS"] doubleValue]);
	out[@"bootTS"] = @([raw[@"bootTS"] doubleValue]);
	out[@"rebootCountBoot"] = @([raw[@"rebootCountBoot"] integerValue]);
	out[@"breaker"] = @([raw[@"breaker"] integerValue]);
	out[@"rebootTimes"] = [raw[@"rebootTimes"] isKindOfClass:[NSArray class]] ? raw[@"rebootTimes"] : @[];
	return out;
}

BOOL TRMonitorStateWrite(NSDictionary *state)
{
	return TRWriteJSON(TRMonitorStatePath(), state, NULL);
}

double TRMonitorCurrentBootTime(void)
{
	struct timeval boot = {0};
	size_t len = sizeof(boot);
	if (sysctlbyname("kern.boottime", &boot, &len, NULL, 0) != 0)
		return 0;
	return (double)boot.tv_sec;
}

BOOL TRMonitorSampleIsStuck(NSDictionary *s, NSString **reason)
{
	if (reason)
		*reason = nil;

	if (![s[@"ok"] boolValue])
	{
		if (reason)
			*reason = @"读不到电池";
		return NO;
	}

	// ① 硬条件：没插充电器绝不执行
	if (![s[@"external"] boolValue])
	{
		if (reason)
			*reason = @"没插充电器";
		return NO;
	}

	// ② 系统必须认为自己正在充电
	if (![s[@"charging"] boolValue])
	{
		if (reason)
			*reason = @"系统未在充电（已充满/优化充电/高温/涓流）";
		return NO;
	}

	// ③ 电流必须真的接近 0（读不到不能当 0）
	NSNumber *cur = s[@"currentMA"];
	if (cur == nil)
	{
		if (reason)
			*reason = @"电流读数缺失";
		return NO;
	}
	long mA = labs((long)[cur integerValue]);
	if (mA >= TRMON_CURRENT_MA)
	{
		if (reason)
			*reason = [NSString stringWithFormat:@"电流 %ldmA ≥ %dmA（说明在充）", mA, TRMON_CURRENT_MA];
		return NO;
	}

	// ④ 电量没满
	NSNumber *pct = s[@"percent"];
	if (pct && [pct integerValue] >= 100)
	{
		if (reason)
			*reason = @"电量已 100%";
		return NO;
	}

	// ⑤ 没到满容量（满电停充属正常）
	NSNumber *raw = s[@"rawCapacity"];
	NSNumber *rawMax = s[@"rawMaxCapacity"];
	if (raw && rawMax && [rawMax integerValue] > 0 && [raw integerValue] >= [rawMax integerValue])
	{
		if (reason)
			*reason = @"已达满容量";
		return NO;
	}

	// ⑥ 温度在合理区间（避免把高温停充当卡死）
	NSNumber *t = s[@"tempC"];
	if (t && ([t doubleValue] < TRMON_TEMP_MIN_C || [t doubleValue] > TRMON_TEMP_MAX_C))
	{
		if (reason)
			*reason = [NSString stringWithFormat:@"温度 %.1f℃ 超出 %d–%d℃", [t doubleValue],
			                                     TRMON_TEMP_MIN_C, TRMON_TEMP_MAX_C];
		return NO;
	}

	return YES;
}

NSString *TRMonitorSafetyBlock(NSDictionary *st)
{
	double now = (double)time(NULL);

	// 熔断
	NSInteger breaker = [st[@"breaker"] integerValue];
	if (breaker >= TRMON_BREAKER_COUNT)
		return [NSString stringWithFormat:@"熔断中（连续已重启 %ld 次，需人工重置）", (long)breaker];

	// 一次开机最多几次
	NSInteger perBoot = [st[@"rebootCountBoot"] integerValue];
	if (perBoot >= TRMON_MAX_PER_BOOT)
		return [NSString stringWithFormat:@"本次开机已自动重启 %ld 次（上限 %d）", (long)perBoot, TRMON_MAX_PER_BOOT];

	// 冷却
	double last = [st[@"lastRebootTS"] doubleValue];
	if (last > 0 && (now - last) < (double)TRMON_COOLDOWN_SEC)
		return [NSString stringWithFormat:@"冷却中（还差 %ld 秒）", (long)((double)TRMON_COOLDOWN_SEC - (now - last))];

	// 每小时 / 24 小时
	NSArray *times = st[@"rebootTimes"] ?: @[];
	NSInteger hour = 0, day = 0;
	for (id v in times)
	{
		double ts = [v doubleValue];
		if (now - ts <= 3600)
			hour++;
		if (now - ts <= 86400)
			day++;
	}
	if (hour >= TRMON_MAX_PER_HOUR)
		return [NSString stringWithFormat:@"本小时已重启 %ld 次（上限 %d）", (long)hour, TRMON_MAX_PER_HOUR];
	if (day >= TRMON_MAX_PER_DAY)
		return [NSString stringWithFormat:@"24 小时内已重启 %ld 次（上限 %d）", (long)day, TRMON_MAX_PER_DAY];

	return nil;
}

NSString *TRMonitorConditionsText(void)
{
	return [NSString stringWithFormat:
	         @"条件（写死）：插电＋在充＋|电流|<%dmA＋电量<100%%＋未满容量＋温度 %d–%d℃",
	         TRMON_CURRENT_MA, TRMON_TEMP_MIN_C, TRMON_TEMP_MAX_C];
}
