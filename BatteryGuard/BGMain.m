// BatteryGuard.dylib —— 注入「电池助手 1.0.7」用
//
// 设计原则（用户定的）：
//   * 绝对不碰 App 自己的电池读取 / 机型信息代码，只做「加一层能力」；
//   * 电池数据不自己另读一份：把 App 已经读到的那一份**原样转发**过来用（桥接，不裁剪字段）；
//   * 联合条件写死在程序里，界面只留一个「多少分钟」输入框 + 保存 + 立即重启；
//   * 拔电即清零，宁漏报不误重启；重启走 TrollStore helper（persona 99 + uid 0）；
//   * 每 2 秒滚动输出一次：App 原始数据 + 归一化读数 + 联合条件 + 安全三项。
//
// 复用 TrollReboot 的三块已验证代码：TRBattery（仅在 App 数据缺失时兜底）、
// TRMonitor（条件/持久化/安全约束）、TRRootOps（spawnRoot + trollstorehelper reboot）。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <time.h>
#import <math.h>
#import <pthread.h>
#import <stdlib.h>
#import <dispatch/dispatch.h>

#import "TRBattery.h"
#import "TRMonitor.h"
#import "TRRootOps.h"

#define BG_TAG @"BatteryGuard 1.3 rules"
#define BGDIR @"/var/mobile/Library/Caches/com.wan.batterychargeguard"
#define BG_TICK_SEC 2.0
#define BG_LOG_MAX 512 * 1024

extern int reboot(int);

#pragma mark - 日志（滚动，超限自动截断重开）

static NSString *BGLogPath(void)
{
	static NSString *path = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[[NSFileManager defaultManager] createDirectoryAtPath:BGDIR
		                          withIntermediateDirectories:YES
		                                           attributes:nil
		                                                error:nil];
		path = [BGDIR stringByAppendingPathComponent:@"guard.log"];
	});
	return path;
}

static void BGLog(NSString *line)
{
	if (line.length == 0)
		return;

	time_t now = time(NULL);
	struct tm tmv;
	localtime_r(&now, &tmv);
	char ts[32];
	strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);

	NSString *full = [NSString stringWithFormat:@"%s %@\n", ts, line];
	NSData *d = [full dataUsingEncoding:NSUTF8StringEncoding];
	if (!d)
		return;

	NSString *path = BGLogPath();
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
	if ([[attr objectForKey:NSFileSize] unsignedLongLongValue] > BG_LOG_MAX)
	{
		NSString *old = [path stringByAppendingString:@".1"];
		[fm removeItemAtPath:old error:nil];
		[fm moveItemAtPath:path toPath:old error:nil];
	}

	int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0)
		return;
	ssize_t ignore = write(fd, d.bytes, d.length);
	(void)ignore;
	fsync(fd);
	close(fd);
}

#pragma mark - 通用取值

static id BGInvoke(id target, SEL sel)
{
	if (!target || ![target respondsToSelector:sel])
		return nil;

	NSMethodSignature *sig = [target methodSignatureForSelector:sel];
	if (!sig)
		return nil;

	NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
	[inv setTarget:target];
	[inv setSelector:sel];
	@try
	{
		[inv invoke];
	}
	@catch (NSException *e)
	{
		return nil;
	}

	if (sig.methodReturnLength == 0)
		return nil;

	__unsafe_unretained id ret = nil;
	[inv getReturnValue:&ret];
	return ret;
}

static id BGPick(NSDictionary *d, NSArray<NSString *> *keys)
{
	if ([d isKindOfClass:[NSDictionary class]] == NO)
		return nil;

	for (NSString *k in keys)
	{
		id v = d[k];
		if (v)
			return v;
	}
	// 大小写/空格不敏感再找一轮（App 的键名风格未知，这一层保证不丢）
	for (NSString *k in keys)
	{
		NSString *want = [[k lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
		for (NSString *kk in d)
		{
			NSString *have = [[[kk description] lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
			if ([have isEqualToString:want])
				return d[kk];
		}
	}
	return nil;
}

static NSNumber *BGNumber(id v)
{
	if ([v isKindOfClass:[NSNumber class]])
		return v;
	if ([v isKindOfClass:[NSString class]])
	{
		NSScanner *sc = [NSScanner scannerWithString:(NSString *)v];
		double d = 0;
		if ([sc scanDouble:&d])
			return @(d);
	}
	return nil;
}

static NSNumber *BGBool(id v)
{
	if ([v isKindOfClass:[NSNumber class]])
		return @([v boolValue]);
	if ([v isKindOfClass:[NSString class]] == NO)
		return nil;

	NSString *s = [(NSString *)v lowercaseString];
	if ([s rangeOfString:@"未"].location != NSNotFound)
		return @NO;
	if ([s rangeOfString:@"false"].location != NSNotFound)
		return @NO;
	if ([s rangeOfString:@"no"].location != NSNotFound)
		return @NO;
	if ([s rangeOfString:@"true"].location != NSNotFound)
		return @YES;
	if ([s rangeOfString:@"yes"].location != NSNotFound)
		return @YES;
	if ([s isEqualToString:@"1"])
		return @YES;
	if ([s rangeOfString:@"是"].location != NSNotFound)
		return @YES;
	return nil;
}

static NSNumber *BGNumberAfter(NSString *text, NSString *label)
{
	if (text.length == 0 || label.length == 0)
		return nil;

	NSRange r = [text rangeOfString:label];
	if (r.location == NSNotFound)
		return nil;

	NSUInteger start = r.location + r.length;
	NSUInteger len = MIN((NSUInteger)32, text.length - start);
	NSString *tail = [text substringWithRange:NSMakeRange(start, len)];

	NSScanner *sc = [NSScanner scannerWithString:tail];
	NSCharacterSet *skip = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789-."] invertedSet];
	[sc setCharactersToBeSkipped:skip];

	double d = 0;
	if ([sc scanDouble:&d])
		return @(d);
	return nil;
}

static NSNumber *BGPercent(NSString *text)
{
	if (text.length == 0)
		return nil;

	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([0-9]{1,3})\\s*%" options:0 error:nil];
	NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
	if (!m)
		return nil;
	NSString *num = [text substringWithRange:[m rangeAtIndex:1]];
	return @([num integerValue]);
}

static NSNumber *BGFlag(NSString *text, NSArray<NSString *> *noWords, NSArray<NSString *> *yesWords)
{
	if (text.length == 0)
		return nil;

	// 先看否定词（「未插电」「未在充电」「已充满」里也含肯定词）
	for (NSString *w in noWords)
		if ([text rangeOfString:w].location != NSNotFound)
			return @NO;
	for (NSString *w in yesWords)
		if ([text rangeOfString:w].location != NSNotFound)
			return @YES;
	return nil;
}

#pragma mark - 主线程桥接：把 App 自己读到的数据整份拿出来

static NSDictionary *BGAppDataOnMain(NSString **sourceName)
{
	NSMutableDictionary *merged = [NSMutableDictionary dictionary];
	NSMutableArray<NSString *> *sources = [NSMutableArray array];

	// ① 电池助手自己的工具类：+[BatteryUtil shareInfolist]（App 内部就是靠它拿完整字段）
	Class buClass = NSClassFromString(@"BatteryUtil");
	if (buClass)
	{
		id r = BGInvoke((id)buClass, NSSelectorFromString(@"shareInfolist"));
		if (r)
		{
			[sources addObject:@"BatteryUtil.shareInfolist"];
			if ([r isKindOfClass:[NSDictionary class]])
			{
				[merged addEntriesFromDictionary:(NSDictionary *)r];
			}
			else if ([r isKindOfClass:[NSArray class]])
			{
				NSInteger idx = 0;
				for (id item in (NSArray *)r)
				{
					if ([item isKindOfClass:[NSDictionary class]])
						[merged addEntriesFromDictionary:(NSDictionary *)item];
					else
						[merged setObject:[item description]
						           forKey:[NSString stringWithFormat:@"item-%ld", (long)idx]];
					idx++;
				}
			}
			else
			{
				[merged setObject:[r description] forKey:@"shareInfolist"];
			}
		}
	}

	// ② App 自己的 ViewController：GetBatteryInfo 等取值入口（同名不同实现都试一遍）
	UIWindow *key = [UIApplication sharedApplication].keyWindow;
	id root = key.rootViewController;
	for (NSString *selName in @[ @"GetBatteryInfo", @"getBatteryInfo", @"batteryInfo", @"shareInfolist" ])
	{
		id r = BGInvoke(root, NSSelectorFromString(selName));
		if (!r)
			continue;
		[sources addObject:[@"vc." stringByAppendingString:selName]];
		if ([r isKindOfClass:[NSDictionary class]])
			[merged addEntriesFromDictionary:(NSDictionary *)r];
		else
			[merged setObject:[r description] forKey:selName];
	}

	if (sourceName)
		*sourceName = sources.count ? [sources componentsJoinedByString:@"+"] : @"none";

	return merged.count ? merged : nil;
}

/// App 界面上正在显示的文字，整份拼起来（不截断）——App 只往 UILabel 上写文本时靠它
static void BGCollectTexts(UIView *v, NSMutableArray<NSString *> *out, NSMutableSet<NSString *> *seen, NSUInteger *budget)
{
	if (!v || *budget == 0)
		return;

	NSString *t = nil;
	if ([v isKindOfClass:[UILabel class]])
		t = ((UILabel *)v).text;
	else if ([v isKindOfClass:[UITextView class]])
		t = ((UITextView *)v).text;
	else if ([v isKindOfClass:[UIButton class]])
		t = [((UIButton *)v) titleForState:UIControlStateNormal];

	if (t.length && ![seen containsObject:t])
	{
		[seen addObject:t];
		[out addObject:t];
		if (*budget > 0)
			(*budget)--;
	}

	for (UIView *sub in v.subviews)
		BGCollectTexts(sub, out, seen, budget);
}

static NSString *BGAppTextOnMain(void)
{
	UIWindow *key = [UIApplication sharedApplication].keyWindow;
	if (!key)
		return @"";
	NSMutableArray<NSString *> *texts = [NSMutableArray array];
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	NSUInteger budget = 80;
	BGCollectTexts(key, texts, seen, &budget);
	return [texts componentsJoinedByString:@" | "];
}

#pragma mark - 归一化：App 原始字段 → 联合条件需要的字段（原字段全部保留）

static NSDictionary *BGMakeSample(NSDictionary *app, NSString *text)
{
	NSMutableDictionary *s = [NSMutableDictionary dictionary];
	if (app)
		[s addEntriesFromDictionary:app];          // 原样转发：App 有多少字段就带多少字段
	if (text)
		s[@"appText"] = text;

	NSNumber *ext = BGBool(BGPick(app, @[ @"ExternalConnected", @"ExternalConnect", @"External", @"已插电" ]));
	NSNumber *chg = BGBool(BGPick(app, @[ @"IsCharging", @"Charging", @"正在充电" ]));
	NSNumber *pct = BGNumber(BGPick(app, @[ @"Current Capacity", @"CurrentCapacity", @"BatteryLevel", @"电量" ]));
	NSNumber *cur = BGNumber(BGPick(app, @[ @"InstantAmperage", @"Amperage", @"Current", @"电流" ]));
	NSNumber *tmp = BGNumber(BGPick(app, @[ @"Temperature", @"温度" ]));
	NSNumber *raw = BGNumber(BGPick(app, @[ @"AppleRawCurrentCapacity", @"RawCurrentCapacity", @"实时容量" ]));
	NSNumber *rawMax = BGNumber(BGPick(app, @[ @"AppleRawMaxCapacity", @"RawMaxCapacity", @"最大容量" ]));

	// 文本兜底（App 把值直接画在 UILabel 上、字典里没有时）
	if (!pct)
		pct = BGPercent(text);
	if (!cur)
		cur = BGNumberAfter(text, @"电流");
	if (!tmp)
		tmp = BGNumberAfter(text, @"温度");
	if (!ext)
		ext = BGFlag(text, @[ @"未插电", @"未连接充电器", @"电池供电" ], @[ @"已插电", @"已连接充电器", @"充电器已连接" ]);
	if (!chg)
		chg = BGFlag(text, @[ @"未在充电", @"已充满", @"未充电" ], @[ @"充电中", @"正在充电" ]);

	// 温度：字典值单位不确定（电池助手给 0.01℃、IOKit 给 0.1℃），反复除 10 直到落进合理量程
	if (tmp)
	{
		double t = [tmp doubleValue];
		int guard = 0;
		while (fabs(t) > 150.0 && guard < 4)
		{
			t /= 10.0;
			guard++;
		}
		tmp = (fabs(t) <= 150.0) ? @(t) : nil;
	}

	// App 界面上直接显示的「电池当前温度：24.9°C」是最可信的，优先用它
	NSNumber *textTemp = BGNumberAfter(text, @"温度");
	if (textTemp)
	{
		double tt = [textTemp doubleValue];
		if (tt > -20.0 && tt < 80.0)
			tmp = @(tt);
	}

	// 电流同理：界面文本「电池当前电流：-123mA」优先
	NSNumber *textCurrent = BGNumberAfter(text, @"电流");
	if (textCurrent)
	{
		double cc = [textCurrent doubleValue];
		if (fabs(cc) <= 10000.0)
			cur = @(cc);
	}

	if (!pct && raw && rawMax && [rawMax doubleValue] > 0)
		pct = @(round([raw doubleValue] * 100.0 / [rawMax doubleValue]));

	if (ext)
		s[@"external"] = ext;
	if (chg)
		s[@"charging"] = chg;
	if (pct)
		s[@"percent"] = pct;
	if (cur)
		s[@"currentMA"] = cur;
	if (tmp)
		s[@"tempC"] = tmp;
	if (raw)
		s[@"rawCapacity"] = raw;
	if (rawMax)
		s[@"rawMaxCapacity"] = rawMax;

	BOOL haveSomething = (app.count > 0) || (text.length > 0);
	BOOL usable = (ext != nil && chg != nil && (pct != nil || (raw && rawMax)) && tmp != nil && cur != nil);
	s[@"ok"] = @(haveSomething);
	s[@"usable"] = @(usable);
	if (!usable)
		s[@"error"] = haveSomething ? @"App 数据里缺少判定字段" : @"拿不到 App 数据";
	return s;
}

#pragma mark - 面板

static UILabel *gBodyLabel = nil;
static UILabel *gHeadLabel = nil;

static void BGUpdateText(NSString *text)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (gBodyLabel)
			gBodyLabel.text = text;
	});
}

#pragma mark - 重启

static BOOL BGFindHelper(NSString **best, NSString **detail)
{
	NSArray<NSString *> *cands = TRHelperCandidates();
	NSString *fresh = nil;
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	for (NSString *p in cands)
	{
		NSString *ver = nil;
		NSDictionary *s = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
		ver = [NSString stringWithFormat:@"%llu", [[s objectForKey:NSFileSize] unsignedLongLongValue]];
		[lines addObject:[NSString stringWithFormat:@"%@(%@)", p, ver ?: @"?"]];
		if (!fresh)
			fresh = p;
	}
	if (detail)
		*detail = lines.count ? [lines componentsJoinedByString:@", "] : @"无候选";
	if (best)
		*best = fresh;
	return fresh != nil;
}

static void BGRecordTrigger(NSString *why)
{
	NSMutableDictionary *st = [TRMonitorStateLoad() mutableCopy];
	if (!st)
		st = [NSMutableDictionary dictionary];

	double now = (double)time(NULL);
	st[@"lastRebootTS"] = @(now);
	st[@"breaker"] = @([st[@"breaker"] integerValue] + 1);
	st[@"rebootCountBoot"] = @([st[@"rebootCountBoot"] integerValue] + 1);
	NSMutableArray *times = [NSMutableArray array];
	id rawTimes = st[@"rebootTimes"];
	if ([rawTimes isKindOfClass:[NSArray class]])
		[times addObjectsFromArray:(NSArray *)rawTimes];
	[times addObject:@(now)];
	st[@"rebootTimes"] = times;
	TRMonitorStateWrite(st);
	BGLog([NSString stringWithFormat:@"[reboot] 记录触发：%@（本次开机第 %ld 次，熔断计数 %ld）", why,
	                                 (long)[st[@"rebootCountBoot"] integerValue],
	                                 (long)[st[@"breaker"] integerValue]]);
}

static void BGDoReboot(NSString *why)
{
	BGLog([NSString stringWithFormat:@"[reboot] 触发：%@ (uid=%d euid=%d)", why, getuid(), geteuid()]);
	BGRecordTrigger(why);

	NSString *helper = nil;
	NSString *detail = nil;
	if (BGFindHelper(&helper, &detail))
	{
		BGLog([NSString stringWithFormat:@"[reboot] trollstorehelper=%@ 候选=%@", helper, detail]);
		NSString *out = nil;
		NSString *err = nil;
		int rc = TRSpawnRoot(helper, @[ @"reboot" ], &out, &err);
		BGLog([NSString stringWithFormat:@"[reboot] trollstorehelper rc=%d out=%@ err=%@",
		                                 rc, out ?: @"-", err ?: @"-"]);
		if (rc == 0)
		{
			sleep(4);
			return;
		}
	}
	else
	{
		BGLog([NSString stringWithFormat:@"[reboot] 未找到 trollstorehelper（候选=%@）", detail ?: @"无"]);
	}

	for (NSString *path in @[ @"/sbin/reboot", @"/usr/bin/reboot" ])
	{
		if (![[NSFileManager defaultManager] isExecutableFileAtPath:path])
			continue;
		BGLog([NSString stringWithFormat:@"[reboot] 回退 %@", path]);
		NSString *out = nil;
		NSString *err = nil;
		int rc = TRSpawnRoot(path, @[], &out, &err);
		BGLog([NSString stringWithFormat:@"[reboot] %@ rc=%d out=%@ err=%@", path, rc, out ?: @"-", err ?: @"-"]);
		if (rc == 0)
		{
			sleep(4);
			return;
		}
	}

	BGLog(@"[reboot] 全部路径失败，调用 reboot(0) 兜底");
	sync();
	reboot(0);
	sleep(3);
	BGLog(@"[reboot] reboot(0) 返回，但没有重启（权限不足）");
}

#pragma mark - 安全三项

static NSString *BGSafetyText(NSDictionary *st)
{
	double now = (double)time(NULL);
	NSMutableArray<NSString *> *parts = [NSMutableArray array];

	double last = [st[@"lastRebootTS"] doubleValue];
	double cool = last > 0 ? (last + TRMON_COOLDOWN_SEC - now) : 0;
	[parts addObject:[NSString stringWithFormat:@"冷却%@", cool > 0 ? [NSString stringWithFormat:@"(%.0fs)", cool] : @"✓"]];

	NSInteger perBoot = [st[@"rebootCountBoot"] integerValue];
	[parts addObject:[NSString stringWithFormat:@"开机%ld/%d%@", (long)perBoot, TRMON_MAX_PER_BOOT,
	                                            perBoot >= TRMON_MAX_PER_BOOT ? @"✗" : @"✓"]];

	NSInteger perHour = 0;
	NSInteger perDay = 0;
	NSArray *times = st[@"rebootTimes"];
	if ([times isKindOfClass:[NSArray class]])
	{
		for (id t in times)
		{
			double ts = [t doubleValue];
			if (ts > now - 3600)
				perHour++;
			if (ts > now - 86400)
				perDay++;
		}
	}
	[parts addObject:[NSString stringWithFormat:@"小时%ld/%d%@", (long)perHour, TRMON_MAX_PER_HOUR,
	                                            perHour >= TRMON_MAX_PER_HOUR ? @"✗" : @"✓"]];
	[parts addObject:[NSString stringWithFormat:@"天%ld/%d%@", (long)perDay, TRMON_MAX_PER_DAY,
	                                            perDay >= TRMON_MAX_PER_DAY ? @"✗" : @"✓"]];

	NSInteger breaker = [st[@"breaker"] integerValue];
	[parts addObject:[NSString stringWithFormat:@"熔断%ld/%d%@", (long)breaker, TRMON_BREAKER_COUNT,
	                                            breaker >= TRMON_BREAKER_COUNT ? @"✗" : @"✓"]];

	return [parts componentsJoinedByString:@" "];
}

#pragma mark - 主循环

static NSInteger gStuckSec = 0;
static NSInteger gGraceSec = 0;
static NSInteger gTickSeq = 0;
static NSUInteger gRawPos = 0;
static BOOL gRebooting = NO;

/// 规则说明：全部数值从常量现取，改常量就跟着变，不再写死一句话
static NSString *BGRuleText(void)
{
	return [NSString stringWithFormat:
	        @"规则: 插电+在充+未满+温度%d-%d℃+|电流|<%dmA 持续%ld分(容忍%ds)\n"
	        @"安全: 冷却%ld分/开机%d次/小时%d次/天%d次/熔断%d次",
	        TRMON_TEMP_MIN_C, TRMON_TEMP_MAX_C, TRMON_CURRENT_MA,
	        (long)TRMonitorStuckMinutes(), TRMON_GRACE_SEC,
	        (long)(TRMON_COOLDOWN_SEC / 60), TRMON_MAX_PER_BOOT,
	        TRMON_MAX_PER_HOUR, TRMON_MAX_PER_DAY, TRMON_BREAKER_COUNT];
}

static void BGTick(void)
{
	gTickSeq++;

	__block NSDictionary *app = nil;
	__block NSString *sourceName = nil;
	__block NSString *text = nil;

	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			app = BGAppDataOnMain(&sourceName);
			text = BGAppTextOnMain();
		}
		dispatch_semaphore_signal(sem);
	});

	if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC))) != 0)
	{
		sourceName = @"主线程未响应";
		BGLog(@"[读] 主线程 1.5s 未返回，本轮视为无数据");
	}

	NSDictionary *sample = BGMakeSample(app, text);

	NSString *reason = nil;
	BOOL softOnly = NO;
	BOOL stuck = TRMonitorSampleIsStuck(sample, &reason, &softOnly);
	BOOL usable = [sample[@"usable"] boolValue];

	// 累计逻辑
	NSString *accum = @"";
	if (stuck)
	{
		gStuckSec += (NSInteger)BG_TICK_SEC;
		gGraceSec = 0;
	}
	else if (softOnly && gStuckSec > 0)
	{
		gGraceSec += (NSInteger)BG_TICK_SEC;
		if (gGraceSec > TRMON_GRACE_SEC)
		{
			gStuckSec = 0;
			gGraceSec = 0;
		}
	}
	else
	{
		gStuckSec = 0;
		gGraceSec = 0;
	}

	NSInteger minutes = TRMonitorStuckMinutes();
	NSInteger needSec = minutes * 60;
	accum = [NSString stringWithFormat:@"累计%lds/需%lds(分钟=%ld)", (long)gStuckSec, (long)needSec, (long)minutes];

	NSDictionary *state = TRMonitorStateLoad();
	NSString *block = TRMonitorSafetyBlock(state);
	NSString *safety = BGSafetyText(state);

	// App 原始字段（不打印）：这里只用来做归一化，日志与面板都不再输出原始 dump

	NSString *norm = [NSString stringWithFormat:@"电量=%@ 电流=%@mA 温度=%@℃ 插电=%@ 在充=%@",
	                           sample[@"percent"] ?: @"?",
	                           sample[@"currentMA"] ?: @"?",
	                           sample[@"tempC"] ?: @"?",
	                           [sample[@"external"] boolValue] ? @"Y" : (sample[@"external"] ? @"N" : @"?"),
	                           [sample[@"charging"] boolValue] ? @"Y" : (sample[@"charging"] ? @"N" : @"?")];

	NSString *cond = stuck ? @"满足" : [NSString stringWithFormat:@"不满足(%@)", reason ?: @"?"];
	if (gGraceSec > 0)
		cond = [cond stringByAppendingFormat:@" 容忍%ld/%ds", (long)gGraceSec, TRMON_GRACE_SEC];

	NSMutableArray<NSString *> *panel = [NSMutableArray array];
	[panel addObject:[NSString stringWithFormat:@"#%ld 源:%@", (long)gTickSeq, sourceName ?: @"?"]];
	[panel addObject:norm];
	[panel addObject:[NSString stringWithFormat:@"条件:%@", cond]];
	[panel addObject:accum];
	[panel addObject:[NSString stringWithFormat:@"安全:%@", safety]];
	[panel addObject:BGRuleText()];
	if (block)
		[panel addObject:[NSString stringWithFormat:@"阻断:%@", block]];
	if (sample[@"error"])
		[panel addObject:[NSString stringWithFormat:@"缺失:%@", sample[@"error"]]];

	BGUpdateText([panel componentsJoinedByString:@"\n"]);

	BGLog([NSString stringWithFormat:@"[tick %ld] %@", (long)gTickSeq, [panel componentsJoinedByString:@" / "]]);

	// —— 到阈值才动手 ——
	if (stuck && gStuckSec >= needSec && !gRebooting)
	{
		if (block)
		{
			BGLog([NSString stringWithFormat:@"[monitor] 条件已满但被拦下：%@", block]);
			gStuckSec = 0;
		}
		else
		{
			gRebooting = YES;
			BGLog([NSString stringWithFormat:@"[monitor] ✅ 条件成立（连续 %lds / 需 %lds / %@）",
			                                 (long)gStuckSec, (long)needSec, norm]);
			BGDoReboot(@"充电卡死");
			gStuckSec = 0;
			gRebooting = NO;
		}
	}
}

static void BGStartTimer(void)
{
	static dispatch_source_t timer = nil;
	if (timer)
		return;

	dispatch_queue_t q = dispatch_queue_create("com.wan.batterychargeguard.tick", DISPATCH_QUEUE_SERIAL);
	timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
	dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
	                          (uint64_t)(BG_TICK_SEC * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
	dispatch_source_set_event_handler(timer, ^{
		@autoreleasepool
		{
			BGTick();
		}
	});
	dispatch_resume(timer);
	BGLog([NSString stringWithFormat:@"[init] 定时器已启动：每 %.0f 秒一轮", BG_TICK_SEC]);
}

#pragma mark - 面板搭建

static void BGInstallPanel(void)
{
	if (gBodyLabel)
		return;
	UIWindow *key = [UIApplication sharedApplication].keyWindow;
	if (!key)
		return;

	CGFloat width = key.bounds.size.width;
	CGFloat height = 172;
	CGRect frame = CGRectMake(10, key.bounds.size.height - height - 8, width - 20, height);

	UIView *panel = [[UIView alloc] initWithFrame:frame];
	panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.9];
	panel.layer.cornerRadius = 12;
	panel.layer.masksToBounds = YES;

	// —— 顶部一行：分钟输入 + 保存 + 立即重启（放在最上面，不压住下面滚动信息）——
	UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(10, 8, 46, 28)];
	field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
	field.textColor = [UIColor whiteColor];
	field.textAlignment = NSTextAlignmentCenter;
	field.keyboardType = UIKeyboardTypeNumberPad;
	field.layer.cornerRadius = 6;
	field.font = [UIFont boldSystemFontOfSize:13];
	field.text = [NSString stringWithFormat:@"%ld", (long)TRMonitorStuckMinutes()];
	[panel addSubview:field];

	UILabel *unit = [[UILabel alloc] initWithFrame:CGRectMake(58, 8, 30, 28)];
	unit.textColor = [UIColor colorWithWhite:1 alpha:0.72];
	unit.font = [UIFont systemFontOfSize:10];
	unit.text = @"分钟";
	[panel addSubview:unit];

	UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
	save.frame = CGRectMake(90, 8, 56, 28);
	save.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
	[save setTitle:@"保存" forState:UIControlStateNormal];
	[save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	save.titleLabel.font = [UIFont boldSystemFontOfSize:11];
	save.layer.cornerRadius = 6;
	__weak UIButton *weakSave = save;
	__weak UITextField *weakField = field;
	[save addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
		NSInteger want = [weakField.text integerValue];
		NSString *detail = nil;
		BOOL ok = TRMonitorWriteStuckMinutes(want, &detail);
		BGLog([NSString stringWithFormat:@"[ui] 保存分钟数=%ld ok=%d detail=%@", (long)want, ok, detail ?: @"-"]);
		[weakSave setTitle:(ok ? @"已存" : @"失败") forState:UIControlStateNormal];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[weakSave setTitle:@"保存" forState:UIControlStateNormal];
		});
	} ] forControlEvents:UIControlEventTouchUpInside];
	[panel addSubview:save];

	UIButton *rebootBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	rebootBtn.frame = CGRectMake(150, 8, frame.size.width - 160, 28);
	rebootBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.15 alpha:1];
	[rebootBtn setTitle:@"立即重启" forState:UIControlStateNormal];
	[rebootBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	rebootBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
	rebootBtn.layer.cornerRadius = 6;
	[rebootBtn addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
		BGLog(@"[ui] 用户点击「立即重启」");
		BGDoReboot(@"用户手动");
	} ] forControlEvents:UIControlEventTouchUpInside];
	[panel addSubview:rebootBtn];

	gHeadLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 40, frame.size.width - 20, 12)];
	gHeadLabel.textColor = [UIColor colorWithRed:0.45 green:0.9 blue:0.55 alpha:1];
	gHeadLabel.font = [UIFont boldSystemFontOfSize:9.5];
	gHeadLabel.text = [[BG_TAG stringByAppendingString:@" · 2s · 源App"] copy];
	[panel addSubview:gHeadLabel];

	gBodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 54, frame.size.width - 20, 112)];
	gBodyLabel.numberOfLines = 0;
	gBodyLabel.textColor = [UIColor whiteColor];
	gBodyLabel.font = [UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightRegular];
	gBodyLabel.text = @"启动中…（等第一轮 2s 采样）";
	[panel addSubview:gBodyLabel];

	[key addSubview:panel];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
	{
		gHeadLabel.text = [[BG_TAG stringByAppendingFormat:@" · 2s · 源%@", @"App"] copy];
	});

	BGLog(@"[init] 面板已安装");
}

#pragma mark - 入口

__attribute__((constructor)) static void BGInit(void)
{
	@autoreleasepool
	{
		TRMonitorSetDirectory(BGDIR);
		BGLog(@"================ BatteryGuard 启动 ================");
		BGLog([NSString stringWithFormat:@"[init] %@，进程 %@，uid=%d euid=%d", BG_TAG,
		                                 [[NSProcessInfo processInfo] processName], getuid(), geteuid()]);

		Class bu = NSClassFromString(@"BatteryUtil");
		BGLog([NSString stringWithFormat:@"[init] BatteryUtil=%@ shareInfolist=%@",
		                                 bu ? @"有" : @"无",
		                                 (bu && [bu respondsToSelector:NSSelectorFromString(@"shareInfolist")]) ? @"有" : @"无"]);

		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
			BGLog(@"[init] didFinishLaunching");
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				BGInstallPanel();
				BGStartTimer();
			});
		}];
		[nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
			BGLog(@"[init] didBecomeActive");
			BGInstallPanel();
			BGStartTimer();
		}];

		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			BGInstallPanel();
			BGStartTimer();
		});
	}
}
