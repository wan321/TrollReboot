#import "TRBattery.h"

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

static FnIOServiceGetMatchingService gGetMatchingService = NULL;
static FnIOServiceMatching gServiceMatching = NULL;
static FnIORegistryEntryCreateCFProperties gCreateCFProperties = NULL;
static FnIOObjectRelease gObjectRelease = NULL;
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

	CFMutableDictionaryRef matching = gServiceMatching("AppleSmartBattery");
	if (matching == NULL)
	{
		out[@"error"] = @"IOServiceMatching(AppleSmartBattery) -> NULL";
		return out;
	}

	io_service_t service = gGetMatchingService(0, matching);
	CFRelease(matching);
	if (service == 0)
	{
		out[@"error"] = @"AppleSmartBattery 服务不存在（读不到电池）";
		return out;
	}

	CFMutableDictionaryRef props = NULL;
	kern_return_t kr = gCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
	gObjectRelease(service);

	if (kr != KERN_SUCCESS || props == NULL)
	{
		out[@"error"] = [NSString stringWithFormat:@"IORegistryEntryCreateCFProperties kr=%d", (int)kr];
		return out;
	}

	NSDictionary *p = CFBridgingRelease(props);

	out[@"ok"] = @YES;
	out[@"properties"] = p;

	NSNumber *instant = TRNum(p[@"InstantAmperage"]);
	if (instant == nil)
		instant = TRNum(p[@"Amperage"]);
	if (instant)
		out[@"currentMA"] = instant;

	NSNumber *voltage = TRNum(p[@"Voltage"]);
	if (voltage)
		out[@"voltageMV"] = voltage;

	NSNumber *temp = TRNum(p[@"Temperature"]);
	if (temp)
		out[@"temperatureDeciC"] = temp;

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
	NSNumber *temp = s[@"temperatureDeciC"];
	NSNumber *pct = s[@"percent"];
	NSNumber *raw = s[@"rawCapacity"];
	NSNumber *rawMax = s[@"rawMaxCapacity"];

	NSString *tempStr = @"?";
	if (temp)
		tempStr = [NSString stringWithFormat:@"%.1f℃", [temp doubleValue] / 10.0];

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

	return [NSString stringWithFormat:@"%s 插电=%@ 充电=%@ 电流=%@mA 电压=%@mV 温度=%@ 电量=%@ 满=%@%@",
	                                  hhmmss,
	                                  [s[@"external"] boolValue] ? @"是" : @"否",
	                                  [s[@"charging"] boolValue] ? @"是" : @"否",
	                                  cur ? [NSString stringWithFormat:@"%ld", (long)[cur integerValue]] : @"?",
	                                  volt ? [NSString stringWithFormat:@"%ld", (long)[volt integerValue]] : @"?",
	                                  tempStr,
	                                  capStr,
	                                  [s[@"fullyCharged"] boolValue] ? @"是" : @"否",
	                                  stuck];
}
