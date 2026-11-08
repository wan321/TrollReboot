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

// ============ 直连 IOKit（与「电池助手 1.0.7」同一条路：真符号，不走 dlopen） ============
// 电池助手静态链接 /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit，
// 服务名用 IOPMPowerSource。我们同样直连，避免 dlsym 拿到空指针。
typedef unsigned int TRIOService;

extern kern_return_t IOMasterPort(mach_port_t bootstrapPort, mach_port_t *masterPort);
extern CFMutableDictionaryRef IOServiceMatching(const char *name);
extern TRIOService IOServiceGetMatchingService(mach_port_t masterPort, CFDictionaryRef matching);
extern kern_return_t IORegistryEntryCreateCFProperties(TRIOService entry, CFMutableDictionaryRef *properties,
                                                       CFAllocatorRef allocator, unsigned int options);
extern kern_return_t IOObjectRelease(TRIOService object);

extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
extern CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps);

static const char *TRServiceNames[] = { "IOPMPowerSource", "AppleSmartBattery", "AppleARMPMUCharger" };

static NSMutableDictionary *TRReadViaLinked(NSString **errOut)
{
	NSMutableDictionary *merged = [NSMutableDictionary dictionary];
	NSMutableString *errs = [NSMutableString string];

	mach_port_t mp = MACH_PORT_NULL;
	kern_return_t kr = IOMasterPort(MACH_PORT_NULL, &mp);
	if (kr != KERN_SUCCESS)
	{
		[errs appendFormat:@"IOMasterPort kr=%d ", (int)kr];
		mp = MACH_PORT_NULL;
	}

	for (size_t i = 0; i < sizeof(TRServiceNames) / sizeof(TRServiceNames[0]); i++)
	{
		CFMutableDictionaryRef matching = IOServiceMatching(TRServiceNames[i]);
		if (matching == NULL) { [errs appendFormat:@"%s:matching=NULL ", TRServiceNames[i]]; continue; }
		TRIOService svc = IOServiceGetMatchingService(mp, matching);
		CFRelease(matching);
		if (svc == 0) { [errs appendFormat:@"%s:service=0 ", TRServiceNames[i]]; continue; }
		CFMutableDictionaryRef props = NULL;
		kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
		IOObjectRelease(svc);
		if (kr != KERN_SUCCESS || props == NULL) { [errs appendFormat:@"%s:props kr=%d ", TRServiceNames[i], (int)kr]; continue; }
		NSDictionary *d = CFBridgingRelease(props);
		if ([d isKindOfClass:[NSDictionary class]]) merged[@(TRServiceNames[i])] = d;
		else [errs appendFormat:@"%s:props not dict ", TRServiceNames[i]];
	}

	if (merged.count == 0)
	{
		if (errOut) *errOut = errs.length ? errs : @"直连 IOKit 读不到";
		return nil;
	}
	return merged;
}

static NSDictionary *TRPublicPowerRead(void)
{
	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	CFTypeRef blob = IOPSCopyPowerSourcesInfo();
	if (blob == NULL) { out[@"error"] = @"IOPSCopyPowerSourcesInfo=NULL"; return out; }
	CFArrayRef list = IOPSCopyPowerSourcesList(blob);
	if (list == NULL || CFArrayGetCount(list) == 0)
	{
		out[@"error"] = @"power source list empty";
		if (list) CFRelease(list);
		CFRelease(blob);
		return out;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(list); i++)
	{
		CFTypeRef ps = CFArrayGetValueAtIndex(list, i);
		CFDictionaryRef desc = IOPSGetPowerSourceDescription(blob, ps);
		if (desc == NULL) continue;
		NSDictionary *d = (__bridge NSDictionary *)desc;
		id transport = d[@"Transport Type"];
		if (transport && [transport isEqual:@"InternalBattery"])
		{
			out[@"ok"] = @YES;
			out[@"source"] = @"public";
			if (d[@"Current Capacity"]) out[@"percent"] = d[@"Current Capacity"];
			if (d[@"Max Capacity"]) out[@"maxCapacity"] = d[@"Max Capacity"];
			if (d[@"Is Charging"]) out[@"charging"] = @([d[@"Is Charging"] boolValue]);
			if (d[@"Is Charged"]) out[@"fullyCharged"] = @([d[@"Is Charged"] boolValue]);
			NSString *state = d[@"Power Source State"];
			if (state) out[@"external"] = @([state isEqualToString:@"AC Power"]);
			if (d[@"Current"]) out[@"currentMA"] = d[@"Current"];
			if (d[@"Voltage"]) out[@"voltageMV"] = d[@"Voltage"];
			if (d[@"Temperature"]) out[@"tempRaw"] = d[@"Temperature"];
			break;
		}
	}
	if (list) CFRelease(list);
	CFRelease(blob);
	return out;
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

	// ① 直连 IOKit（和「电池助手」同一条路）
	NSString *linkErr = nil;
	NSMutableDictionary *merged = TRReadViaLinked(&linkErr);
	int created = (int)merged.count;
	int tried = created;
	if (merged == nil) merged = [NSMutableDictionary dictionary];

	// ② 直连拿不到 → 退回 dlopen/dlsym（老路，保留兼容）
	if (created == 0 && TRLoadIOKit())
	{
		mach_port_t masterPort = MACH_PORT_NULL;
		if (gMasterPort)
		{
			kern_return_t mkr = gMasterPort(MACH_PORT_NULL, &masterPort);
			if (mkr != KERN_SUCCESS) masterPort = MACH_PORT_NULL;
		}
		for (size_t i = 0; i < sizeof(TRServiceNames) / sizeof(TRServiceNames[0]); i++)
		{
			CFMutableDictionaryRef matching = gServiceMatching(TRServiceNames[i]);
			if (matching == NULL) continue;
			io_service_t service = gGetMatchingService(masterPort, matching);
			CFRelease(matching);
			if (service == 0) continue;
			CFMutableDictionaryRef props = NULL;
			kern_return_t kr = gCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
			gObjectRelease(service);
			tried++;
			if (kr != KERN_SUCCESS || props == NULL) continue;
			NSDictionary *d = CFBridgingRelease(props);
			if ([d isKindOfClass:[NSDictionary class]]) { merged[@(TRServiceNames[i])] = d; created++; }
		}
	}

	if (created == 0)
	{
		NSDictionary *pub = TRPublicPowerRead();
		out[@"public"] = pub;
		out[@"error"] = [NSString stringWithFormat:@"私有读不到（link: %@ | dlopen: %@）公开: %@",
		                                           linkErr ?: @"-",
		                                           gIOKitError[0] ? @(gIOKitError) : @"-",
		                                           pub[@"error"] ?: @"ok"];
		if ([pub[@"ok"] boolValue])
		{
			out[@"ok"] = @YES;
			out[@"source"] = pub[@"source"] ?: @"public";
			for (NSString *k in @[@"percent", @"maxCapacity", @"charging", @"fullyCharged", @"external", @"currentMA", @"voltageMV", @"tempRaw"])
				if (pub[k]) out[k] = pub[k];
		}
		return out;
	}

	NSDictionary *p = merged[@"IOPMPowerSource"] ?: merged[@"AppleSmartBattery"] ?: merged[@"AppleARMPMUCharger"];
	NSDictionary *alt = merged[@"AppleARMPMUCharger"] ?: merged[@"AppleSmartBattery"] ?: merged[@"IOPMPowerSource"];

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
	// 私有服务里没有电流时，用公开 API 补一次（部分机型 IOPMPowerSource 不带 Current）
	if (out[@"currentMA"] == nil || out[@"percent"] == nil)
	{
		NSDictionary *pub = TRPublicPowerRead();
		out[@"public"] = pub;
		if (out[@"currentMA"] == nil && pub[@"currentMA"]) out[@"currentMA"] = pub[@"currentMA"];
		if (out[@"percent"] == nil && pub[@"percent"]) out[@"percent"] = pub[@"percent"];
		if (out[@"external"] == nil && pub[@"external"]) out[@"external"] = pub[@"external"];
	}

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
