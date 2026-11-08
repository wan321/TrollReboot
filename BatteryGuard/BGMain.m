// BatteryGuard.dylib —— 注入「电池助手 1.0.7」用
//
// 设计原则（用户定的）：
//   * 绝对不碰 App 自己的电池读取 / 机型信息代码，只做「加一层能力」；
//   * 联合条件写死在程序里，界面只留一个「多少分钟」输入框 + 保存 + 立即重启；
//   * 拔电即清零，宁漏报不误重启；重启走 TrollStore helper（persona 99 + uid 0）。
//
// 复用 TrollReboot 的三块已验证代码：TRBattery（读电池）、TRMonitor（条件/持久化/安全约束）、
// TRRootOps（spawnRoot + trollstorehelper reboot）。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <time.h>
#import <stdlib.h>

#import "TRBattery.h"
#import "TRMonitor.h"
#import "TRRootOps.h"

#define BG_TAG @"BatteryGuard 1.0"
#define BGDIR @"/var/mobile/Library/Caches/com.wan.batterychargeguard"

extern int reboot(int);

#pragma mark - 日志

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
	if (d.length == 0)
		return;

	int fd = open(BGLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0)
		return;
	const char *bytes = (const char *)d.bytes;
	size_t left = d.length;
	while (left > 0)
	{
		ssize_t n = write(fd, bytes, left);
		if (n <= 0)
			break;
		bytes += n;
		left -= (size_t)n;
	}
	fsync(fd);
	close(fd);
}

#pragma mark - 共享状态

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static double gStuckSec = 0;
static double gGraceSec = 0;
static NSString *gNote = @"启动中";
static BOOL gRebooting = NO;
static NSInteger gTicks = 0;
static NSString *gLastBatteryLine = @"";

static UILabel *gStatusLabel = nil;
static UITextField *gMinField = nil;
static UIView *gPanel = nil;

static void BGSetNote(NSString *note)
{
	pthread_mutex_lock(&gLock);
	gNote = [note copy];
	pthread_mutex_unlock(&gLock);
}

static NSDictionary *BGLive(void)
{
	pthread_mutex_lock(&gLock);
	NSDictionary *d = @{ @"stuckSec" : @(gStuckSec), @"note" : gNote ?: @"" };
	pthread_mutex_unlock(&gLock);
	return d;
}

#pragma mark - 重启

static BOOL BGDoReboot(NSString *why)
{
	if (gRebooting)
		return NO;
	gRebooting = YES;

	BGLog([NSString stringWithFormat:@"[reboot] 触发：%@（uid=%u euid=%u）", why, getuid(), geteuid()]);
	sync();

	NSString *helper = TRFindTrollStoreHelper();
	int rc = -1;
	NSString *err = nil;
	if (helper.length > 0)
	{
		rc = TRSpawnRoot(helper, @[ @"reboot" ], nil, &err);
		BGLog([NSString stringWithFormat:@"[reboot] trollstorehelper=%@ rc=%d err=%@",
		                                 helper, rc, err.length ? err : @"(空)"]);
	}
	else
	{
		BGLog(@"[reboot] 没找到 trollstorehelper，改用 /sbin/reboot");
	}

	if (rc != 0)
	{
		NSString *err2 = nil;
		int rc2 = TRSpawnRoot(@"/sbin/reboot", @[], nil, &err2);
		BGLog([NSString stringWithFormat:@"[reboot] /sbin/reboot rc=%d err=%@", rc2, err2.length ? err2 : @"(空)"]);
		if (rc2 != 0)
		{
			NSString *err3 = nil;
			int rc3 = TRSpawnRoot(@"/usr/bin/reboot", @[], nil, &err3);
			BGLog([NSString stringWithFormat:@"[reboot] /usr/bin/reboot rc=%d err=%@", rc3, err3.length ? err3 : @"(空)"]);
		}
	}

	// 本进程不是 root，这一句通常直接失败；留着当最后一道兜底
	sync();
	int r = reboot(0);
	BGLog([NSString stringWithFormat:@"[reboot] reboot(0) 返回 %d errno=%d", r, errno]);

	gRebooting = NO;
	return YES;
}

#pragma mark - 监控

static void BGPushUI(NSString *status)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (gStatusLabel != nil)
		{
			gStatusLabel.text = status;
			return;
		}
		// 面板还没装（App 可能还在启动），把文本缓存进 note，装面板时会带上
	});
}

static void BGSample(void)
{
	@autoreleasepool
	{
		gTicks++;

		NSDictionary *sample = TRBatteryRead();
		NSString *batteryLine = TRBatteryLine(sample);
		gLastBatteryLine = batteryLine;

		NSInteger minutes = TRMonitorStuckMinutes();
		double need = (double)minutes * 60.0;

		if (![sample[@"ok"] boolValue])
		{
			pthread_mutex_lock(&gLock);
			gStuckSec = 0;
			gGraceSec = 0;
			pthread_mutex_unlock(&gLock);
			BGSetNote(@"读不到电池，本轮清零");
			BGPushUI([NSString stringWithFormat:@"%@ ｜ 读不到电池\n%@", BG_TAG, sample[@"error"] ?: @"?"]);
			return;
		}

		BOOL soft = NO;
		NSString *reason = nil;
		BOOL stuck = TRMonitorSampleIsStuck(sample, &reason, &soft);
		BOOL powered = [sample[@"external"] boolValue];

		if (!powered)
		{
			// 拔电：硬闸立即清零
			pthread_mutex_lock(&gLock);
			gStuckSec = 0;
			gGraceSec = 0;
			pthread_mutex_unlock(&gLock);
		}
		else if (stuck)
		{
			pthread_mutex_lock(&gLock);
			gStuckSec += (double)TRMON_SAMPLE_SEC;
			gGraceSec = 0;
			pthread_mutex_unlock(&gLock);
		}
		else if (soft)
		{
			pthread_mutex_lock(&gLock);
			if (gStuckSec > 0)
			{
				gGraceSec += (double)TRMON_SAMPLE_SEC;
				if (gGraceSec > (double)TRMON_GRACE_SEC)
				{
					gStuckSec = 0;
					gGraceSec = 0;
				}
			}
			pthread_mutex_unlock(&gLock);
		}
		else
		{
			pthread_mutex_lock(&gLock);
			gStuckSec = 0;
			gGraceSec = 0;
			pthread_mutex_unlock(&gLock);
		}

		// 恢复正常充电 → 熔断计数归零（「连续」才熔断）
		if (powered && !stuck && !soft)
		{
			NSDictionary *st0 = TRMonitorStateLoad();
			if ([st0[@"breaker"] integerValue] > 0)
			{
				NSMutableDictionary *m0 = [st0 mutableCopy];
				m0[@"breaker"] = @0;
				TRMonitorStateWrite(m0);
				BGLog(@"[monitor] 恢复正常充电，熔断计数已归零");
			}
		}

		NSDictionary *live = BGLive();
		double stuckSec = [live[@"stuckSec"] doubleValue];

		if (stuck)
			BGSetNote([NSString stringWithFormat:@"卡死样 已累计 %ld 秒 / 需 %ld 秒",
			                                     (long)stuckSec, (long)need]);
		else if (soft && stuckSec > 0)
			BGSetNote([NSString stringWithFormat:@"电流短时恢复，容忍中（%ld 秒 / 需 %ld 秒）",
			                                     (long)stuckSec, (long)need]);
		else
			BGSetNote([NSString stringWithFormat:@"不满足：%@", reason ?: @"?"]);

		BOOL willFire = NO;

		if (stuck && stuckSec >= need)
		{
			NSDictionary *st = TRMonitorStateLoad();
			double boot = TRMonitorCurrentBootTime();
			NSMutableDictionary *st2 = [st mutableCopy];

			if (boot > 0 && fabs([st2[@"bootTS"] doubleValue] - boot) > 1.0)
			{
				st2[@"bootTS"] = @(boot);
				st2[@"rebootCountBoot"] = @0;
				TRMonitorStateWrite(st2);
			}

			NSString *block = TRMonitorSafetyBlock(st2);
			if (block != nil)
			{
				BGSetNote([NSString stringWithFormat:@"条件成立但被安全约束挡住：%@", block]);
				BGLog([NSString stringWithFormat:@"[monitor] 拦下：%@", block]);
			}
			else
			{
				willFire = YES;
				double now = (double)time(NULL);
				NSMutableArray *times = [NSMutableArray arrayWithArray:st2[@"rebootTimes"] ?: @[]];
				[times addObject:@(now)];
				while (times.count > 32)
					[times removeObjectAtIndex:0];

				st2[@"lastRebootTS"] = @(now);
				st2[@"rebootCountBoot"] = @([st2[@"rebootCountBoot"] integerValue] + 1);
				st2[@"breaker"] = @([st2[@"breaker"] integerValue] + 1);
				st2[@"rebootTimes"] = times;
				TRMonitorStateWrite(st2);

				BGLog([NSString stringWithFormat:
					   @"[monitor] ✅ 条件成立（连续 %ld 秒 / 需 %ld 分钟 / 电量 %@%% / 电流 %@mA），执行重启",
					   (long)stuckSec, (long)minutes,
					   sample[@"percent"] ?: @"?", sample[@"currentMA"] ?: @"?"]);

				BGDoReboot(@"充电卡死");
			}
		}

		// UI
		NSDictionary *st3 = TRMonitorStateLoad();
		NSString *block3 = TRMonitorSafetyBlock(st3);
		NSMutableString *ui = [NSMutableString string];
		[ui appendFormat:@"%@ ｜ 已运行 %ld 秒\n", BG_TAG, (long)gTicks * TRMON_SAMPLE_SEC];
		[ui appendFormat:@"%@\n", live[@"note"] ?: @""];
		if (willFire)
			[ui appendString:@"正在执行重启…"];
		else if (block3.length > 0)
			[ui appendFormat:@"⚠ 已停止自动重启：%@", block3];
		else
			[ui appendString:@"🟢 自动重启：可用"];

		BGPushUI(ui);
	}
}

static void BGStartTimer(void)
{
	dispatch_queue_t q = dispatch_queue_create("com.wan.batterychargeguard.monitor", DISPATCH_QUEUE_SERIAL);
	dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
	dispatch_source_set_timer(timer,
	                          dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC),
	                          (uint64_t)TRMON_SAMPLE_SEC * NSEC_PER_SEC,
	                          1ull * NSEC_PER_SEC);
	dispatch_source_set_event_handler(timer, ^{
		BGSample();
	});
	dispatch_resume(timer);
}

#pragma mark - 面板

static UITextField *BGTextField(CGRect frame)
{
	UITextField *f = [[UITextField alloc] initWithFrame:frame];
	f.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
	f.textColor = [UIColor whiteColor];
	f.font = [UIFont systemFontOfSize:13];
	f.textAlignment = NSTextAlignmentCenter;
	f.keyboardType = UIKeyboardTypeNumberPad;
	f.layer.cornerRadius = 6;
	return f;
}

static UIButton *BGButton(CGRect frame, NSString *title)
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	b.frame = frame;
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
	b.layer.cornerRadius = 6;
	return b;
}

static void BGInstallPanel(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (gPanel != nil)
			return;

		UIWindow *win = UIApplication.sharedApplication.keyWindow;
		if (win == nil && UIApplication.sharedApplication.windows.count > 0)
			win = UIApplication.sharedApplication.windows.firstObject;
		if (win == nil)
			return;

		CGRect b = win.bounds;
		CGFloat w = b.size.width - 16.0;
		CGFloat h = 96.0;
		UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(8.0, b.size.height - h - 28.0, w, h)];
		panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.74];
		panel.layer.cornerRadius = 12.0;
		panel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;

		UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(10.0, 6.0, w - 20.0, 46.0)];
		status.numberOfLines = 3;
		status.font = [UIFont systemFontOfSize:10.5];
		status.textColor = [UIColor whiteColor];
		status.text = [NSString stringWithFormat:@"%@ 启动中…", BG_TAG];
		[panel addSubview:status];

		UITextField *field = BGTextField(CGRectMake(10.0, 58.0, 46.0, 28.0));
		field.text = [NSString stringWithFormat:@"%ld", (long)TRMonitorStuckMinutes()];
		[panel addSubview:field];

		UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(62.0, 58.0, 130.0, 28.0)];
		hint.text = @"分钟不动就重启";
		hint.font = [UIFont systemFontOfSize:11];
		hint.textColor = [UIColor whiteColor];
		[panel addSubview:hint];

		UIButton *save = BGButton(CGRectMake(w - 132.0, 58.0, 56.0, 28.0), @"保存");
		[panel addSubview:save];

		UIButton *rb = BGButton(CGRectMake(w - 68.0, 58.0, 58.0, 28.0), @"立即重启");
		[panel addSubview:rb];

		[win addSubview:panel];
		gPanel = panel;
		gStatusLabel = status;
		gMinField = field;

		// 保存分钟数：校验范围 1–60，写入配置文件并回读确认
		[save addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
			NSInteger m = [gMinField.text integerValue];
			if (m < TRMON_MINUTES_MIN) m = TRMON_MINUTES_MIN;
			if (m > TRMON_MINUTES_MAX) m = TRMON_MINUTES_MAX;
			gMinField.text = [NSString stringWithFormat:@"%ld", (long)m];
			NSString *detail = nil;
			BOOL ok = TRMonitorWriteStuckMinutes(m, &detail);
			NSInteger readback = TRMonitorStuckMinutesFromFile();
			BGLog([NSString stringWithFormat:@"[ui] 保存分钟数 %ld ok=%d readback=%ld detail=%@",
			                                     (long)m, ok, (long)readback, detail ?: @"?"]);
			[gMinField resignFirstResponder];
		}] forControlEvents:UIControlEventTouchUpInside];

		[rb addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
			BGLog(@"[ui] 手动点击「立即重启」");
			BGDoReboot(@"手动点击");
		}] forControlEvents:UIControlEventTouchUpInside];
	});
}

#pragma mark - 启动

__attribute__((constructor)) static void BGInit(void)
{
	// 先把状态目录切到自己的，避免和 TrollReboot 守护共享 monitor.state / monitor.conf
	TRMonitorSetDirectory(@"/var/mobile/Library/Caches/com.wan.batterychargeguard");

	BGLog(@"============================================================");
	BGLog([NSString stringWithFormat:@"[init] %@ 载入 pid=%d uid=%u euid=%u", BG_TAG, getpid(), getuid(), geteuid()]);

	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
	                                                  object:nil
	                                                   queue:[NSOperationQueue mainQueue]
	                                              usingBlock:^(NSNotification *n) {
		BGLog(@"[init] UIApplicationDidFinishLaunching");
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			BGInstallPanel();
		});
	}];

	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
	                                                  object:nil
	                                                   queue:[NSOperationQueue mainQueue]
	                                              usingBlock:^(NSNotification *n) {
		BGInstallPanel();
	}];

	// App 若已经启动完（dylib 在 main 之前载入，通常还没），补一次
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4ull * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		BGInstallPanel();
	});

	BGStartTimer();
}
