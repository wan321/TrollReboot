//
//  BGRequestServer.m —— 守护进程版快捷指令入口（v1.5）
//
//  为什么会需要它：
//    dylib 的 HTTP 入口只活在「电池助手」这个 App 进程里，App 一退就没了；
//    快捷指令要「什么都不用打开、什么都不用唤醒」就能执行，就得有一个常驻进程占着回环端口。
//
//  它能做到什么：
//    - 监听 127.0.0.1:8899，回环地址不弹「本地网络」授权；
//    - 自己读电池（IOPMPowerSource）并按 TRMonitor 的联合条件判断；
//    - /trigger 立即重启（trollstorehelper → /sbin/reboot → /usr/bin/reboot → reboot(0)）；
//    - /listen?value=1 打开「常驻监控」，满足条件时不等 App 自己动手。
//
//  它做不到什么：
//    - 重启后的第一次解锁之前，任何快捷指令都跑不起来（Data Protection），这是系统限制。
//    - 它不是越狱守护进程，被 iOS 回收后需要 App 再拉起一次（App 每次启动都会补一次）。
//
//  只用 Foundation + IOKit + POSIX，不依赖 UIKit。
//

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <stdarg.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <signal.h>
#import <sys/stat.h>

#import "TRBattery.h"
#import "TRMonitor.h"
#import "TRRootOps.h"

// 有的 iOS SDK 头里没有 reboot() 原型，显式声明，避免隐式声明警告被当成错误
extern int reboot(int);

#define BGREQ_PORT 8899
#define BGREQ_TAG @"BatteryGuard 1.5 reqd"
#define BGREQ_DIR @"/var/mobile/Library/Caches/com.wan.batterychargeguard"
#define BGREQ_LOG BGREQ_DIR @"/guard.log"
#define BGREQ_LISTEN_CFG BGREQ_DIR @"/listen.conf"
#define BGREQ_TICK_SEC 2.0
#define BGREQ_GRACE_SEC 60

static double gStuckSec = 0;
static double gGraceSec = 0;
static unsigned long long gTick = 0;
static BOOL gRebooting = NO;
static NSDictionary *gLastSample = nil;
static NSDictionary *gLastReason = nil;

#pragma mark - 日志

static void BGReqLog(NSString *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);

	NSString *line = [NSString stringWithFormat:@"%@ [reqd] %@\n",
	                  [NSDateFormatter localizedStringFromDate:[NSDate date]
	                                                 dateStyle:NSDateFormatterNoStyle
	                                                 timeStyle:NSDateFormatterMediumStyle],
	                  body];
	NSLog(@"[bgreqd] %@", body);

	NSString *path = BGREQ_LOG;
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createDirectoryAtPath:BGREQ_DIR withIntermediateDirectories:YES attributes:nil error:nil];

	NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
	if (attr && [attr fileSize] > 512 * 1024)
	{
		[fm removeItemAtPath:[path stringByAppendingString:@".1"] error:nil];
		[fm moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
	}

	NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!fh)
	{
		[fm createFileAtPath:path contents:nil attributes:nil];
		fh = [NSFileHandle fileHandleForWritingAtPath:path];
	}
	[fh seekToEndOfFile];
	[fh writeData:d];
	[fh synchronizeFile];
	[fh closeFile];
}

#pragma mark - 小工具

static NSString *BGReqJSON(id obj)
{
	if (!obj || ![NSJSONSerialization isValidJSONObject:obj])
		return @"{}";
	NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
	return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

static BOOL BGReqListenEnabled(void)
{
	NSString *s = [NSString stringWithContentsOfFile:BGREQ_LISTEN_CFG encoding:NSUTF8StringEncoding error:nil];
	return s.length > 0 && [s integerValue] != 0;
}

static void BGReqSetListen(BOOL on)
{
	[@"1\n" writeToFile:BGREQ_LISTEN_CFG atomically:YES encoding:NSUTF8StringEncoding error:nil];
	if (!on)
		[@"0\n" writeToFile:BGREQ_LISTEN_CFG atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *BGReqSafetyText(void)
{
	NSDictionary *st = TRMonitorStateLoad();
	NSString *block = TRMonitorSafetyBlock(st);
	return block.length ? block : @"可执行";
}

#pragma mark - 采样

static void BGReqTick(void)
{
	@autoreleasepool
	{
		gTick++;

		NSDictionary *sample = TRBatteryRead();
		gLastSample = sample;

		NSString *reason = nil;
		BOOL soft = NO;
		BOOL stuck = TRMonitorSampleIsStuck(sample, &reason, &soft);

		if (stuck)
		{
			gGraceSec = 0;
			gStuckSec += BGREQ_TICK_SEC;
		}
		else if (soft)
		{
			gGraceSec += BGREQ_TICK_SEC;
			if (gGraceSec > BGREQ_GRACE_SEC)
				gStuckSec = 0;
		}
		else
		{
			gGraceSec = 0;
			gStuckSec = 0;
		}

		NSInteger need = TRMonitorStuckMinutes() * 60;
		NSMutableDictionary *d = [NSMutableDictionary dictionary];
		d[@"tick"] = @(gTick);
		d[@"stuckSec"] = @(gStuckSec);
		d[@"needSec"] = @(need);
		d[@"cond"] = reason ?: @"";
		d[@"soft"] = @(soft);
		d[@"listen"] = @(BGReqListenEnabled());
		d[@"safety"] = BGReqSafetyText();
		gLastReason = d;

		// 每 30 秒一条心跳，够定位又不刷爆日志
		if (gTick % 15 == 1)
		{
			BGReqLog(@"采样 #%llu 电量=%@ 电流=%@mA 温度=%@ 插电=%@ 在充=%@ | 条件:%@ | 累计%.0fs/需%lds | 监听:%@ | 安全:%@",
			         gTick,
			         sample[@"percent"] ?: @"?",
			         sample[@"currentMA"] ?: @"?",
			         sample[@"tempC"] ?: @"?",
			         sample[@"external"] ?: @"?",
			         sample[@"charging"] ?: @"?",
			         reason ?: @"-",
			         gStuckSec, (long)need,
			         BGReqListenEnabled() ? @"开" : @"关",
			         BGReqSafetyText());
		}

		if (!gRebooting && BGReqListenEnabled() && stuck && gStuckSec >= need)
		{
			NSString *block = TRMonitorSafetyBlock(TRMonitorStateLoad());
			if (block.length)
			{
				BGReqLog(@"够时间但被安全约束拦住：%@", block);
			}
			else
			{
				BGReqLog(@"达到阈值 %.0fs（需 %lds），执行自动重启", gStuckSec, (long)need);
				gRebooting = YES;

				NSMutableDictionary *st = [TRMonitorStateLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
				st[@"lastRebootTS"] = @([[NSDate date] timeIntervalSince1970]);
				st[@"rebootCountBoot"] = @([st[@"rebootCountBoot"] integerValue] + 1);
				NSMutableArray *times = [st[@"rebootTimes"] mutableCopy] ?: [NSMutableArray array];
				[times addObject:@([[NSDate date] timeIntervalSince1970])];
				if (times.count > 32)
					[times removeObjectAtIndex:0];
				st[@"rebootTimes"] = times;
				TRMonitorStateWrite(st);

				NSString *log = nil;
				if (!TRRequestReboot(&log))
				{
					BGReqLog(@"helper 重启失败：%@", log ?: @"?");
					reboot(0);
				}
			}
		}
	}
}

#pragma mark - HTTP

static NSString *BGReqPathBody(NSString *path, BOOL *doReboot)
{
	*doReboot = NO;

	NSString *query = @"";
	NSString *pure = path;
	NSRange q = [path rangeOfString:@"?"];
	if (q.location != NSNotFound)
	{
		query = [path substringFromIndex:q.location + 1];
		pure = [path substringToIndex:q.location];
	}

	if ([pure hasPrefix:@"/trigger"] || [pure hasPrefix:@"/reboot"])
	{
		*doReboot = YES;
		BGReqLog(@"[http] %@ 请求重启", pure);
		return BGReqJSON(@{ @"ok": @YES, @"role": @"daemon", @"tag": BGREQ_TAG,
		                    @"action": @"reboot", @"delay_ms": @300 });
	}

	if ([pure hasPrefix:@"/listen"])
	{
		BOOL on = ![query containsString:@"value=0"];
		BGReqSetListen(on);
		BGReqLog(@"[http] 常驻监控 %@", on ? @"打开" : @"关闭");
		return BGReqJSON(@{ @"ok": @YES, @"role": @"daemon", @"tag": BGREQ_TAG, @"listen": @(on) });
	}

	NSDictionary *s = gLastSample;
	if ([pure hasPrefix:@"/batteryjson"])
	{
		return BGReqJSON(@{ @"ok": @(s != nil), @"role": @"daemon", @"tag": BGREQ_TAG,
		                    @"source": @"IOPMPowerSource(守护进程)",
		                    @"sample": s ?: @{},
		                    @"judge": gLastReason ?: @{} });
	}

	if ([pure hasPrefix:@"/guard"])
	{
		return BGReqJSON(@{ @"ok": @YES, @"role": @"daemon", @"tag": BGREQ_TAG,
		                    @"judge": gLastReason ?: @{},
		                    @"listen": @(BGReqListenEnabled()),
		                    @"safety": BGReqSafetyText(),
		                    @"minutes": @(TRMonitorStuckMinutes()) });
	}

	return BGReqJSON(@{ @"ok": @YES, @"role": @"daemon", @"tag": BGREQ_TAG,
	                    @"pid": @(getpid()),
	                    @"tick": @(gTick),
	                    @"stuckSec": @(gStuckSec),
	                    @"needSec": @(TRMonitorStuckMinutes() * 60),
	                    @"listen": @(BGReqListenEnabled()),
	                    @"charging": s ? (s[@"charging"] ?: @NO) : @NO,
	                    @"paths": @[ @"/ping", @"/batteryjson", @"/guard", @"/listen?value=1", @"/trigger" ] });
}

static void BGReqServe(int c)
{
	struct timeval tv = { 2, 0 };
	setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

	char buf[1024] = {0};
	ssize_t n = read(c, buf, sizeof(buf) - 1);
	if (n <= 0)
	{
		close(c);
		return;
	}

	NSString *req = [NSString stringWithUTF8String:buf] ?: @"";
	NSArray *parts = [req componentsSeparatedByString:@" "];
	NSString *path = (parts.count >= 2) ? parts[1] : @"/";

	BOOL doReboot = NO;
	NSString *body = BGReqPathBody(path, &doReboot);
	NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
	NSString *head = [NSString stringWithFormat:
	                  @"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
	                  @"Content-Length: %lu\r\nConnection: close\r\n\r\n",
	                  (unsigned long)bd.length];
	NSMutableData *out = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
	[out appendData:bd];
	write(c, out.bytes, (size_t)out.length);
	close(c);

	if (doReboot)
	{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
		               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			               gRebooting = YES;
			               NSString *log = nil;
			               if (!TRRequestReboot(&log))
			               {
				               BGReqLog(@"helper 重启失败：%@ → 直接 reboot(0)", log ?: @"?");
				               reboot(0);
			               }
		               });
	}
}

static int BGReqListenLoop(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
	{
		BGReqLog(@"socket 失败 errno=%d", errno);
		return 1;
	}

	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(BGREQ_PORT);
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 8) < 0)
	{
		BGReqLog(@"绑定 127.0.0.1:%d 失败 errno=%d（可能已有实例在跑）", BGREQ_PORT, errno);
		close(fd);
		return 2;
	}

	BGReqLog(@"守护进程就绪 pid=%d tag=%@ 监听 127.0.0.1:%d", getpid(), BGREQ_TAG, BGREQ_PORT);

	for (;;)
	{
		int c = accept(fd, NULL, NULL);
		if (c < 0)
		{
			if (errno == EINTR)
				continue;
			break;
		}
		BGReqServe(c);
	}

	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	@autoreleasepool
	{
		TRMonitorSetDirectory(BGREQ_DIR);

		if (![NSFileManager.defaultManager fileExistsAtPath:BGREQ_LISTEN_CFG])
			BGReqSetListen(NO);

		BGReqLog(@"启动 tag=%@ pid=%d 常驻监控=%@ 阈值=%ld 分钟",
		         BGREQ_TAG, getpid(),
		         BGReqListenEnabled() ? @"开" : @"关",
		         (long)TRMonitorStuckMinutes());

		dispatch_queue_t q = dispatch_queue_create("com.wan.batterychargeguard.reqdtick", NULL);
		dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
		dispatch_source_set_timer(timer,
		                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
		                          (uint64_t)(BGREQ_TICK_SEC * NSEC_PER_SEC),
		                          200 * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(timer, ^{ BGReqTick(); });
		dispatch_resume(timer);

		BGReqListenLoop();
	}
	return 0;
}
