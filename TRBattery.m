#import "TRBattery.h"
#import "TRMonitor.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <string.h>
#import <errno.h>
#include <time.h>
#include <stdlib.h>

/*
 * v3.5-probe 只读电池探针（iOS 14.4 / iPhone SE2 A13 实测目标）
 *
 * iOS 上 IOKit 是私有框架（没有公开头文件），这里全部走 dlopen + dlsym
 * 动态调用，避免在 Makefile 里引入私有 tbd。与 ChargeLimiter / 电池助手同一条路线：
 *    IOServiceMatching("AppleSmartBattery")
 *    -> IOServiceGetMatchingService(0, matching)
 *    -> IORegistryEntryCreateCFProperties
 *    -> 取 Amperage / InstantAmperage / Voltage / Temperature / CurrentCapacity ...
 *
 * 本文件不做任何写系统状态的操作，也不发重启命令。
 */

typedef uint32_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;
typedef uint32_t IOOptionBits;

typedef io_service_t (*FnIOServiceGetMatchingService)(uint32_t masterPort, CFDictionaryRef matching);
typedef CFMutableDictionaryRef (*FnIOServiceMatching)(const char *name);
typedef kern_return_t (*FnIORegistryEntryCreateCFProperties)(io_registry_entry_t entry,
                                                            CFMutableDictionaryRef *properties,
                                                            CFAllocatorRef allocator,
                                                            IOOptionBits options);
typedef kern_return_t (*FnIOObjectRelease)(io_object_t object);
typedef kern_return_t (*FnIOMasterPort)(mach_port_t bootstrapPort, mach_port_t *masterPort);

static FnIOServiceGetMatchingService gGetMatchingService = NULL;
static FnIOServiceMatching gServiceMatching = NULL;
static FnIORegistryEntryCreateCFProperties gCreateCFProperties = NULL;
static FnIOObjectRelease gObjectRelease = NULL;
static FnIOMasterPort gMasterPort = NULL;
static char gIOKitError[256] = {0};

static BOOL TRLoadIOKit(void)
{
	if (gGetMatchingService != NULL)
		return YES;

	gIOKitError[0] = 0;

	const char *candidates[] = {
		"/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
		"/System/Library/Frameworks/IOKit.framework/IOKit",
		"IOKit",
		"/usr/lib/libIOKit.dylib",
	};

	void *handle = NULL;
	const char *usedPath = NULL;
	for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++)
	{
		handle = dlopen(candidates[i], RTLD_LAZY);
		if (handle != NULL)
		{
			usedPath = candidates[i];
			break;
		}
		const char *e = dlerror();
		snprintf(gIOKitError, sizeof(gIOKitError), "%s: %s", candidates[i], e ? e : "unknown");
	}

	if (handle == NULL)
		return NO;

	gGetMatchingService = (FnIOServiceGetMatchingService)dlsym(handle, "IOServiceGetMatchingService");
	gServiceMatching = (FnIOServiceMatching)dlsym(handle, "IOServiceMatching");
	gCreateCFProperties = (FnIORegistryEntryCreateCFProperties)dlsym(handle, "IORegistryEntryCreateCFProperties");
	gObjectRelease = (FnIOObjectRelease)dlsym(handle, "IOObjectRelease");
	gMasterPort = (FnIOMasterPort)dlsym(handle, "IOMasterPort");

	if (!gGetMatchingService || !gServiceMatching || !gCreateCFProperties || !gObjectRelease)
	{
		snprintf(gIOKitError, sizeof(gIOKitError), "dlopen(%s) ok but dlsym missing symbol",
		         usedPath ? usedPath : "?");
		gGetMatchingService = NULL;
		return NO;
	}
	return YES;
}

static NSNumber *TRNum(id v)
{
	return [v isKindOfClass:[NSNumber class]] ? (NSNumber *)v : nil;
}

NSString *TRProbeLogPath(void)
{
	static NSString *path = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
		[[NSFileManager defaultManager] createDirectoryAtPath:docs
		                          withIntermediateDirectories:YES
		                                           attributes:nil
		                                                error:nil];
		path = [docs stringByAppendingPathComponent:@"charge-probe.log"];
	});
	return path;
}

void TRProbeLogAppend(NSString *line)
{
	NSString *path = TRProbeLogPath();
	NSString *full = [line stringByAppendingString:@"\n"];
	NSData *data = [full dataUsingEncoding:NSUTF8StringEncoding];
	if (data.length == 0)
		return;

	int fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0)
		return;
	const char *bytes = (const char *)data.bytes;
	size_t remaining = data.length;
	while (remaining > 0)
	{
		ssize_t n = write(fd, bytes, remaining);
		if (n <= 0)
			break;
		bytes += n;
		remaining -= (size_t)n;
	}
	fsync(fd); // 掉电/重启也不丢行
	close(fd);
}

NSDictionary *TRBatteryRead(void)
{
	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	out[@"ok"] = @NO;

	if (!TRLoadIOKit())
	{
		out[@"error"] = gIOKitError[0] ? @(gIOKitError) : @"dlopen IOKit failed";
		return out;
	}

	// 参照 EEIOKitListener：先 IOMasterPort 拿 master port。
	// 之前直接给 IOServiceGetMatchingService 传 0，在部分 iOS 上拿不到服务甚至直接把进程带走。
	mach_port_t masterPort = MACH_PORT_NULL;
	if (gMasterPort)
	{
		kern_return_t mkr = gMasterPort(MACH_PORT_NULL, &masterPort);
		if (mkr != KERN_SUCCESS)
		{
			snprintf(gIOKitError, sizeof(gIOKitError), "IOMasterPort kr=%d", (int)mkr);
			masterPort = MACH_PORT_NULL;
		}
	}

	// AppleSmartBattery：容量 / 电流 / 电压 / 温度
	// AppleARMPMUCharger：充电器侧数据（EEIOKitListener 用的就是它）
	const char *serviceNames[] = { "AppleSmartBattery", "AppleARMPMUCharger" };
	NSMutableDictionary *merged = [NSMutableDictionary dictionary];
	int tried = 0;
	int created = 0;

	for (size_t i = 0; i < sizeof(serviceNames) / sizeof(serviceNames[0]); i++)
	{
		CFMutableDictionaryRef matching = gServiceMatching(serviceNames[i]);
		if (matching == NULL)
			continue;

		io_service_t service = gGetMatchingService(masterPort, matching);
		CFRelease(matching);
		if (service == 0)
			continue;

		CFMutableDictionaryRef props = NULL;
		kern_return_t kr = gCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
		gObjectRelease(service);
		tried++;
		if (kr != KERN_SUCCESS || props == NULL)
			continue;

		NSDictionary *d = CFBridgingRelease(props);
		if ([d isKindOfClass:[NSDictionary class]])
		{
			merged[@(serviceNames[i])] = d;
			created++;
		}
	}

	if (created == 0)
	{
		out[@"error"] = [NSString stringWithFormat:@"两个服务都读不到（tried=%d master_port=%u）%@",
		                                           tried, (unsigned)masterPort,
		                                           gIOKitError[0] ? @(gIOKitError) : @""];
		return out;
	}

	NSDictionary *p = merged[@"AppleSmartBattery"] ?: merged[@"AppleARMPMUCharger"];
	NSDictionary *alt = merged[@"AppleARMPMUCharger"] ?: merged[@"AppleSmartBattery"];

	out[@"ok"] = @YES;
	out[@"properties"] = p;
	out[@"services"] = [merged.allKeys componentsJoinedByString:@","];

	// 电流：两个服务里谁有就用谁（charger 的 Amperage 在快充时更贴近实际）
	NSNumber *instant = TRNum(p[@"InstantAmperage"]);
	if (instant == nil) instant = TRNum(alt[@"InstantAmperage"]);
	if (instant == nil) instant = TRNum(p[@"Amperage"]);
	if (instant == nil) instant = TRNum(alt[@"Amperage"]);
	if (instant)
		out[@"currentMA"] = instant;

	NSNumber *voltage = TRNum(p[@"Voltage"]);
	if (voltage == nil) voltage = TRNum(alt[@"Voltage"]);
	if (voltage)
		out[@"voltageMV"] = voltage;

	NSNumber *temp = TRNum(p[@"Temperature"]);
	if (temp == nil) temp = TRNum(alt[@"Temperature"]);
	if (temp)
	{
		// 这个字段不同机型单位不一样：多数是 0.1℃（2769 → 27.7℃），
		// 也有以 0.1K 报的（3001 → 27.0℃）。按量级自动判断，避免显示成 276.9℃。
		double raw = [temp doubleValue];
		double deciC = raw / 10.0;
		double degC = (deciC >= 5.0 && deciC <= 80.0) ? deciC : (deciC - 273.15);
		out[@"tempC"] = @(degC);
		out[@"tempRaw"] = temp;
	}

	NSNumber *cap = TRNum(p[@"CurrentCapacity"]);
	if (cap)
		out[@"percent"] = cap;

	NSNumber *raw = TRNum(p[@"AppleRawCurrentCapacity"]);
	if (raw)
		out[@"rawCapacity"] = raw;

	NSNumber *rawMax = TRNum(p[@"AppleRawMaxCapacity"]);
	if (rawMax)
		out[@"rawMaxCapacity"] = rawMax;

	NSNumber *maxCap = TRNum(p[@"MaxCapacity"]);
	if (maxCap)
		out[@"maxCapacity"] = maxCap;

	// 仪表盘需要的一组：健康度 / 循环次数 / 设计容量
	NSNumber *design = TRNum(p[@"DesignCapacity"]);
	if (design)
		out[@"designCapacity"] = design;

	NSNumber *cycle = TRNum(p[@"CycleCount"]);
	if (cycle)
		out[@"cycleCount"] = cycle;

	NSNumber *nominal = TRNum(p[@"NominalChargeCapacity"]);
	if (nominal)
		out[@"nominalChargeCapacity"] = nominal;

	NSNumber *fullCap = rawMax ?: maxCap;
	if (design && fullCap && [design integerValue] > 0)
	{
		double h = [fullCap doubleValue] * 100.0 / [design doubleValue];
		if (h > 120.0 && maxCap && [design integerValue] > 0)
			h = [maxCap doubleValue] * 100.0 / [design doubleValue];
		out[@"healthPercent"] = @(h);
	}

	if (voltage && instant)
		out[@"powerW"] = @(fabs([voltage doubleValue] * [instant doubleValue]) / 1000000.0);

	out[@"external"] = @([p[@"ExternalConnected"] boolValue]);
	out[@"charging"] = @([p[@"IsCharging"] boolValue]);
	out[@"fullyCharged"] = @([p[@"FullyCharged"] boolValue]);

	return out;
}

BOOL TRBatteryLooksStuck(NSDictionary *s, int currentThresholdMA)
{
	if (![s[@"ok"] boolValue])
		return NO;
	if (![s[@"external"] boolValue])
		return NO;
	if (![s[@"charging"] boolValue])
		return NO;

	NSNumber *cur = s[@"currentMA"];
	if (cur == nil)
		return NO;
	if (labs((long)[cur integerValue]) >= currentThresholdMA)
		return NO;

	NSNumber *raw = s[@"rawCapacity"];
	NSNumber *rawMax = s[@"rawMaxCapacity"];
	if (raw && rawMax && [raw integerValue] >= [rawMax integerValue])
		return NO; // 已经满了，不算卡住

	NSNumber *pct = s[@"percent"];
	if (pct && [pct integerValue] >= 100)
		return NO;

	return YES;
}

/// 监控判定预览（只判断、不执行任何动作）：把 7 条联合条件逐条走一遍，
/// 返回「会触发 / 不会触发（原因）」，方便真机确认监控不会误判。
NSString *TRMonitorVerdict(NSDictionary *s)
{
	if (![s[@"ok"] boolValue])
		return @"监控预览：不触发（读不到电池）";

	if (![s[@"external"] boolValue])
		return @"监控预览：不触发（没插充电器）"; // 硬条件：没插电绝不执行

	if (![s[@"charging"] boolValue])
		return @"监控预览：不触发（系统未在充电：已充满/优化充电/高温/涓流）";

	NSNumber *cur = s[@"currentMA"];
	if (cur == nil)
		return @"监控预览：不触发（电流读数缺失）";

	long mA = labs((long)[cur integerValue]);
	if (mA >= TRMON_CURRENT_MA)
		return [NSString stringWithFormat:@"监控预览：不触发（电流 %ldmA ≥ %dmA）", mA, TRMON_CURRENT_MA];

	NSNumber *pct = s[@"percent"];
	if (pct && [pct integerValue] >= 100)
		return @"监控预览：不触发（电量已 100%）";

	NSNumber *raw = s[@"rawCapacity"];
	NSNumber *rawMax = s[@"rawMaxCapacity"];
	if (raw && rawMax && [raw integerValue] >= [rawMax integerValue])
		return @"监控预览：不触发（已达满容量）";

	NSNumber *t = s[@"tempC"];
	if (t && ([t doubleValue] < TRMON_TEMP_MIN_C || [t doubleValue] > TRMON_TEMP_MAX_C))
		return [NSString stringWithFormat:@"监控预览：不触发（温度 %.1f℃ 超出 %d–%d℃）", [t doubleValue], TRMON_TEMP_MIN_C, TRMON_TEMP_MAX_C];

	return [NSString stringWithFormat:@"监控预览：✅ 条件成立（连续 %ld 分钟都这样才会重启）", (long)TRMonitorStuckMinutes()];
}

NSString *TRBatteryLine(NSDictionary *s)
{
	time_t now = time(NULL);
	struct tm tmv;
	localtime_r(&now, &tmv);
	char hhmmss[16];
	snprintf(hhmmss, sizeof(hhmmss), "%02d:%02d:%02d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

	if (![s[@"ok"] boolValue])
	{
		return [NSString stringWithFormat:@"%s ❌ 读取失败：%@", hhmmss, s[@"error"] ?: @"?"];
	}

	NSNumber *cur = s[@"currentMA"];
	NSNumber *volt = s[@"voltageMV"];
	NSNumber *temp = s[@"tempC"];
	NSNumber *pct = s[@"percent"];
	NSNumber *raw = s[@"rawCapacity"];
	NSNumber *rawMax = s[@"rawMaxCapacity"];

	NSString *tempStr = @"?";
	if (temp)
	{
		tempStr = [NSString stringWithFormat:@"%.1f℃(raw %ld)", [temp doubleValue],
		                                     (long)[(s[@"tempRaw"] ?: @0) integerValue]];
	}

	NSString *capStr = @"?";
	if (pct)
	{
		if (raw && rawMax)
			capStr = [NSString stringWithFormat:@"%ld%%(raw %ld/%ld)", (long)[pct integerValue],
			                                        (long)[raw integerValue], (long)[rawMax integerValue]];
		else
			capStr = [NSString stringWithFormat:@"%ld%%", (long)[pct integerValue]];
	}

	NSString *stuck = TRBatteryLooksStuck(s, 50) ? @"  ⚠️满足0电流条件" : @"";
	NSString *verdict = TRMonitorVerdict(s);

	return [NSString stringWithFormat:@"%s 插电=%@ 充电=%@ 电流=%@mA 电压=%@mV 温度=%@ 电量=%@ 满=%@%@\n      %@",
	                                  hhmmss,
	                                  [s[@"external"] boolValue] ? @"是" : @"否",
	                                  [s[@"charging"] boolValue] ? @"是" : @"否",
	                                  cur ? [NSString stringWithFormat:@"%ld", (long)[cur integerValue]] : @"?",
	                                  volt ? [NSString stringWithFormat:@"%ld", (long)[volt integerValue]] : @"?",
	                                  tempStr,
	                                  capStr,
	                                  [s[@"fullyCharged"] boolValue] ? @"是" : @"否",
	                                  stuck,
	                                  verdict];
}


#pragma mark - 公开 API 电源信息（不依赖私有注册表）

/*
 * IOPSCopyPowerSourcesInfo / IOPSCopyPowerSourcesList / IOPSGetPowerSourceDescription
 * 都是 IOKit 里的公开符号（不需要头文件，dlsym 即可），只返回「电源描述」，
 * 不触碰 AppleSmartBattery 这类私有服务节点，因此在 App/守护里调用都不会崩。
 *
 * 它给不了电流/电压/温度，但能稳定给出：
 *   - 是否插着外部电源（Battery Power = No）
 *   - 是否在充（Is Charging）
 *   - 电量百分比（Current Capacity / Max Capacity）
 */
NSDictionary *TRPowerSourcesRead(void)
{
	static void *psHandle = NULL;
	static void *(*fnCopyInfo)(void) = NULL;
	static CFArrayRef (*fnCopyList)(CFTypeRef) = NULL;
	static CFDictionaryRef (*fnGetDesc)(CFTypeRef, CFTypeRef) = NULL;
	static BOOL loaded = NO;

	if (!loaded)
	{
		loaded = YES;
		const char *paths[] = {
			"/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
			"/System/Library/Frameworks/IOKit.framework/IOKit",
			"IOKit",
		};
		for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]) && psHandle == NULL; i++)
			psHandle = dlopen(paths[i], RTLD_NOW);

		if (psHandle)
		{
			fnCopyInfo = (void *(*)(void))dlsym(psHandle, "IOPSCopyPowerSourcesInfo");
			fnCopyList = (CFArrayRef (*)(CFTypeRef))dlsym(psHandle, "IOPSCopyPowerSourcesList");
			fnGetDesc = (CFDictionaryRef (*)(CFTypeRef, CFTypeRef))dlsym(psHandle, "IOPSGetPowerSourceDescription");
		}
	}

	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	out[@"ok"] = @NO;
	out[@"source"] = @"public";

	if (!fnCopyInfo || !fnCopyList || !fnGetDesc)
	{
		out[@"error"] = @"公开电源 API 不可用（dlsym 失败）";
		return out;
	}

	CFTypeRef info = fnCopyInfo();
	if (info == NULL)
	{
		out[@"error"] = @"IOPSCopyPowerSourcesInfo 返回空";
		return out;
	}

	CFArrayRef list = fnCopyList(info);
	if (list == NULL)
	{
		CFRelease(info);
		out[@"error"] = @"IOPSCopyPowerSourcesList 返回空";
		return out;
	}

	NSDictionary *picked = nil;
	for (CFIndex i = 0; i < CFArrayGetCount(list); i++)
	{
		CFTypeRef ps = (CFTypeRef)CFArrayGetValueAtIndex(list, i);
		CFDictionaryRef desc = fnGetDesc(info, ps);
		if (desc == NULL)
			continue;
		NSDictionary *d = (__bridge NSDictionary *)desc;
		NSString *type = d[@"Type"];
		if ([type isKindOfClass:[NSString class]] && [type isEqualToString:@"InternalBattery"])
		{
			picked = d;
			break;
		}
		if (picked == nil)
			picked = d;
	}
	CFRelease(list);
	CFRelease(info);

	if (picked == nil)
	{
		out[@"error"] = @"没有内建电池的电源描述";
		return out;
	}

	NSNumber *cur = picked[@"Current Capacity"];
	NSNumber *max = picked[@"Max Capacity"];
	NSNumber *charging = picked[@"Is Charging"];
	NSNumber *batteryPower = picked[@"Battery Power"];

	out[@"ok"] = @YES;
	if ([cur isKindOfClass:[NSNumber class]])
		out[@"percent"] = cur;
	if ([max isKindOfClass:[NSNumber class]])
		out[@"maxCapacity"] = max;
	// Battery Power = NO 代表当前由外部电源供电（即插着充电器）
	out[@"plugged"] = @(![batteryPower isKindOfClass:[NSNumber class]] ? YES : ![batteryPower boolValue]);
	out[@"external"] = out[@"plugged"];
	out[@"charging"] = @([charging isKindOfClass:[NSNumber class]] ? [charging boolValue] : NO);
	out[@"fullyCharged"] = @([cur isKindOfClass:[NSNumber class]] && [max isKindOfClass:[NSNumber class]] &&
	                         [max integerValue] > 0 && [cur integerValue] >= [max integerValue]);
	if ([picked[@"Time to Full Charge"] isKindOfClass:[NSNumber class]])
		out[@"timeToFull"] = picked[@"Time to Full Charge"];

	return out;
}