#import "TRDaemon.h"
#import "TRRootOps.h"
#import "TRBattery.h"
#import "TRMonitor.h"

#include <spawn.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <math.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>

// iOS SDK 里没有 sys/reboot.h，自己声明
extern int reboot(int);

#define TR_DAEMON_PORT     8899
#define TR_DAEMON_LABEL    "com.wan.trollreboot.daemon"
#define TR_DAEMON_PLIST    "/Library/LaunchDaemons/com.wan.trollreboot.daemon.plist"
#define TR_SYSTEM_PLIST    "/System/Library/LaunchDaemons/com.wan.trollreboot.daemon.plist"
#define TR_LAUNCHCTL       "/bin/launchctl"
#define TR_DAEMON_BIN      "/usr/libexec/TrollRebootDaemon"

static NSString *const TRBaseDirPath = @"/var/mobile/Library/Caches/com.wan.trollreboot";

static const char *ctimeString(void);

static NSString *TRPath(NSString *name)
{
	return [TRBaseDirPath stringByAppendingPathComponent:name];
}

static void TREnsureBaseDir(void)
{
	[[NSFileManager defaultManager] createDirectoryAtPath:TRBaseDirPath
	                          withIntermediateDirectories:YES
	                                           attributes:@{NSFilePosixPermissions: @0777}
	                                                error:nil];
}

static void TRAppendLog(NSString *name, NSString *text)
{
	TREnsureBaseDir();
	NSString *path = TRPath(name);
	NSString *line = [NSString stringWithFormat:@"[%s] %@\n", ctimeString(), text];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	NSFileManager *fm = [NSFileManager defaultManager];

	NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
	if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > 128 * 1024)
	{
		[fm removeItemAtPath:path error:nil];
	}

	if ([fm fileExistsAtPath:path])
	{
		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
		[fh seekToEndOfFile];
		[fh writeData:data];
		[fh synchronizeFile];
		[fh closeFile];
	}
	else
	{
		[data writeToFile:path atomically:YES];
	}
}

static const char *ctimeString(void)
{
	static char buf[32];
	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	df.dateFormat = @"HH:mm:ss";
	NSString *s = [df stringFromDate:[NSDate date]];
	strncpy(buf, s.UTF8String ?: "", sizeof(buf) - 1);
	buf[sizeof(buf) - 1] = '\0';
	return buf;
}

static void TRWriteHeartbeat(void)
{
	TREnsureBaseDir();
	NSString *text = [NSString stringWithFormat:@"uid=%u euid=%u pid=%d ts=%ld\n",
		getuid(), geteuid(), getpid(), (long)time(NULL)];
	[[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:TRPath(@"heartbeat") atomically:YES];
}

#pragma mark - 通用命令执行

/// 以 root 执行一条命令，返回 exit code，并把 stdout/stderr 拼进 out
static int TRRunCmd(NSString *path, NSArray<NSString *> *args, NSString **out)
{
	NSString *o = nil;
	NSString *e = nil;
	int rc = TRSpawnRoot(path, args, &o, &e);

	NSMutableString *m = [NSMutableString string];
	[m appendFormat:@"$ %@ %@  →  rc=%d", path.lastPathComponent, [args componentsJoinedByString:@" "], rc];
	NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	if (o.length)
	{
		NSString *t = [o stringByTrimmingCharactersInSet:ws];
		if (t.length) [m appendFormat:@"\n   out: %@", t];
	}
	if (e.length)
	{
		NSString *t = [e stringByTrimmingCharactersInSet:ws];
		if (t.length) [m appendFormat:@"\n   err: %@", t];
	}
	if (out) *out = m;
	return rc;
}

#pragma mark - killall

static void TRKillSpringBoard(void)
{
	int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
	size_t length = 0;
	if (sysctl(mib, 3, NULL, &length, NULL, 0) < 0) return;
	struct kinfo_proc *info = malloc(length);
	if (!info) return;
	if (sysctl(mib, 3, info, &length, NULL, 0) < 0) { free(info); return; }

	int count = (int)(length / sizeof(struct kinfo_proc));
	for (int i = 0; i < count; i++)
	{
		pid_t pid = info[i].kp_proc.p_pid;
		if (pid <= 0) continue;
		char name[64] = {0};
		strncpy(name, info[i].kp_proc.p_comm, sizeof(name) - 1);
		if (strcmp(name, "SpringBoard") == 0)
		{
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"respring: kill(%d, SIGTERM)", pid]);
			kill(pid, SIGTERM);
		}
	}
	free(info);
}

#pragma mark - 心跳线程

static void *TRHeartbeatThread(void *arg)
{
	(void)arg;
	for (;;)
	{
		TRWriteHeartbeat();
		sleep(5);
	}
	return NULL;
}

#pragma mark - HTTP 服务

static void TRRespond(int fd, int code, NSString *body)
{
	NSString *resp = [NSString stringWithFormat:
		@"HTTP/1.1 %d %@\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
		code, code == 200 ? @"OK" : @"ERR",
		(unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding], body];
	const char *bytes = resp.UTF8String;
	size_t left = strlen(bytes);
	while (left > 0)
	{
		ssize_t n = write(fd, bytes, left);
		if (n <= 0) break;
		bytes += n;
		left -= (size_t)n;
	}
}

/// v3.5-probe3：把私有 IOKit 读电池放进 fork 出来的子进程里做。
/// 这样即使 IOKit 把进程搞崩，死的也只是子进程，守护还活着，而且能报出信号号。
/// asJSON=YES 时返回 JSON（给仪表盘用），否则返回一行紧凑文本。
static NSString *TRBatteryReadIsolatedWithFormat(BOOL asJSON)
{
	int fds[2];
	if (pipe(fds) != 0)
		return [NSString stringWithFormat:@"❌ pipe errno=%d", errno];

	pid_t child = fork();
	if (child == 0)
	{
		close(fds[0]);
		@autoreleasepool
		{
			NSDictionary *sample = TRBatteryRead();
			NSString *payload = nil;
			if (asJSON)
			{
				// properties 里是 IOKit 原始对象（可能有 NSData），不能直接进 JSON
				NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithDictionary:sample ?: @{}];
				[safe removeObjectForKey:@"properties"];
				NSData *jd = [NSJSONSerialization dataWithJSONObject:safe options:0 error:NULL];
				payload = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : nil;
				if (payload == nil)
					payload = @"{\"ok\":false,\"error\":\"json encode failed\"}";
			}
			else
			{
				payload = TRBatteryLine(sample);
			}

			NSData *d = [payload dataUsingEncoding:NSUTF8StringEncoding];
			if (d.length > 0)
				(void)write(fds[1], d.bytes, d.length);
		}
		_exit(0);
	}
	close(fds[1]);
	if (child < 0)
	{
		close(fds[0]);
		return [NSString stringWithFormat:@"❌ fork errno=%d", errno];
	}

	int fl = fcntl(fds[0], F_GETFL, 0);
	(void)fcntl(fds[0], F_SETFL, fl | O_NONBLOCK);

	NSMutableData *acc = [NSMutableData data];
	char buf[1024];
	BOOL timedOut = NO;
	NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 3.0;
	for (;;)
	{
		ssize_t n = read(fds[0], buf, sizeof(buf));
		if (n > 0)
		{
			[acc appendBytes:buf length:(NSUInteger)n];
			continue;
		}
		if (n == 0)
			break;
		if (errno != EAGAIN && errno != EWOULDBLOCK)
			break;
		if ([NSDate timeIntervalSinceReferenceDate] > deadline)
		{
			timedOut = YES;
			break;
		}
		usleep(20000);
	}
	close(fds[0]);

	int status = 0;
	pid_t w = waitpid(child, &status, WNOHANG);
	if (w == 0)
	{
		kill(child, SIGKILL);
		(void)waitpid(child, &status, 0);
	}

	if (acc.length > 0)
	{
		NSString *s = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
		return s.length > 0 ? s : @"❌ 读电池返回空";
	}
	if (timedOut)
		return @"❌ 读电池超时（>3s，私有 IOKit 卡住）";
	if (WIFSIGNALED(status))
		return [NSString stringWithFormat:@"❌ 读电池的子进程被信号 %d 杀掉（私有 IOKit 崩了）", WTERMSIG(status)];
	return [NSString stringWithFormat:@"❌ 读电池无输出（子进程 exit=%d）", WEXITSTATUS(status)];
}

static NSString *TRBatteryReadIsolated(void)
{
	return TRBatteryReadIsolatedWithFormat(NO);
}

#pragma mark - v3.5-mon：充电卡死自动重启（条件写死，只开放分钟数）

static double gMonStuckSec = 0;
static double gMonGraceSec = 0;
static double gMonFlatSec = 0;
static NSInteger gMonFlatPct = -1;
static NSString *gMonNote = @"未开始";
static pthread_mutex_t gMonLock = PTHREAD_MUTEX_INITIALIZER;

static void TRMonSetNote(NSString *note)
{
	pthread_mutex_lock(&gMonLock);
	gMonNote = [note copy];
	pthread_mutex_unlock(&gMonLock);
}

static NSDictionary *TRMonLive(void)
{
	pthread_mutex_lock(&gMonLock);
	double stuck = gMonStuckSec;
	NSString *note = gMonNote ?: @"";
	pthread_mutex_unlock(&gMonLock);
	return @{ @"stuckSec" : @(stuck), @"note" : note };
}

static void *TRMonitorThread(void *arg)
{
	(void)arg;

	for (;;)
	{
		@autoreleasepool
		{
			NSInteger minutes = TRMonitorStuckMinutes();
			double need = (double)minutes * 60.0;

			// ① 先用公开 API 取「插电 / 电量 / 是否充满」——这条路径不碰私有注册表，不会崩
			NSDictionary *pub = TRPowerSourcesRead();
			BOOL pubOk = [pub[@"ok"] boolValue];
			BOOL pubPlugged = [pub[@"plugged"] boolValue];
			NSInteger pubPct = [pub[@"percent"] integerValue];
			BOOL pubFull = [pub[@"fullyCharged"] boolValue];
			BOOL pubCharging = [pub[@"charging"] boolValue];

			// ② 再尽力取私有 IOKit（电流/电压/温度）；它崩了也不影响上面的判定
			NSString *raw = TRBatteryReadIsolatedWithFormat(YES);
			NSDictionary *sample = nil;
			if (raw.length > 0)
			{
				NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
				id o = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
				if ([o isKindOfClass:[NSDictionary class]])
					sample = o;
			}

			BOOL haveCurrent = [sample[@"currentMA"] isKindOfClass:[NSNumber class]];
			// ③ 公开电源描述里若也带电流/电压/温度，就直接用（完全不碰私有注册表）
			if (!haveCurrent && [pub[@"currentMA"] isKindOfClass:[NSNumber class]])
			{
				NSMutableDictionary *merged = sample ? [sample mutableCopy] : [NSMutableDictionary dictionary];
				merged[@"currentMA"] = pub[@"currentMA"];
				merged[@"currentSource"] = @"public";
				if ([pub[@"voltageMV"] isKindOfClass:[NSNumber class]])
					merged[@"voltageMV"] = pub[@"voltageMV"];
				if ([pub[@"tempC"] isKindOfClass:[NSNumber class]])
					merged[@"tempC"] = pub[@"tempC"];
				if (merged[@"ok"] == nil)
					merged[@"ok"] = @YES;
				if (merged[@"external"] == nil)
					merged[@"external"] = @(pubPlugged);
				if (merged[@"charging"] == nil)
					merged[@"charging"] = @(pubCharging);
				if (merged[@"percent"] == nil && pubPct > 0)
					merged[@"percent"] = @(pubPct);
				sample = merged;
				haveCurrent = YES;
			}
			BOOL powered = pubPlugged || [sample[@"external"] boolValue];

			BOOL stuck = NO;
			BOOL soft = NO;
			NSString *reason = nil;
			NSString *mode = haveCurrent ? @"电流判据" : @"电量停滞判据";

			if (!pubOk && sample == nil)
			{
				// 两条路都读不到：保守清零
				pthread_mutex_lock(&gMonLock);
				gMonStuckSec = 0;
				gMonGraceSec = 0;
				gMonFlatSec = 0;
				pthread_mutex_unlock(&gMonLock);
				TRMonSetNote(@"读不到电池（公开 API 与 IOKit 都失败），本轮清零");
				sleep(TRMON_SAMPLE_SEC);
				continue;
			}

			if (haveCurrent)
			{
				stuck = TRMonitorSampleIsStuck(sample, &reason, &soft);
			}
			else
			{
				// 电量停滞判据：插电 + 未满 + 电量连续 N 分钟纹丝不动
				pthread_mutex_lock(&gMonLock);
				if (!pubPlugged || pubFull || pubPct <= 0) {
					gMonFlatSec = 0;
					gMonFlatPct = -1;
					pthread_mutex_unlock(&gMonLock);
					reason = !pubPlugged ? @"未插外部电源" : (pubFull ? @"电量已满" : @"读不到电量");
				} else if (gMonFlatPct != pubPct) {
					gMonFlatPct = pubPct;
					gMonFlatSec = 0;
					pthread_mutex_unlock(&gMonLock);
					reason = [NSString stringWithFormat:@"电量仍在变化（%ld%%）", (long)pubPct];
				} else {
					gMonFlatSec += TRMON_SAMPLE_SEC;
					double flat = gMonFlatSec;
					pthread_mutex_unlock(&gMonLock);
					if (flat >= need)
					{
						stuck = YES;
						// 电量停滞已达阈值：把累计量直接推到阈值，立刻进入触发判定（不必再等一轮）
						pthread_mutex_lock(&gMonLock);
						if (gMonStuckSec < need)
							gMonStuckSec = need;
						pthread_mutex_unlock(&gMonLock);
					}
					else
						reason = [NSString stringWithFormat:@"电量 %ld%% 已停滞 %ld 秒 / 需 %ld 秒（无电流数据）",
						                                    (long)pubPct, (long)flat, (long)need];
				}
				(void)pubCharging;
			}
			if (!powered)
			{
				// 拔电：立即清零（硬闸，宁漏报不误重启）
				pthread_mutex_lock(&gMonLock);
				gMonStuckSec = 0;
				gMonGraceSec = 0;
				gMonFlatSec = 0;
				gMonFlatPct = -1;
				pthread_mutex_unlock(&gMonLock);
			}
			else if (stuck)
			{
				pthread_mutex_lock(&gMonLock);
				gMonStuckSec += TRMON_SAMPLE_SEC;
				gMonGraceSec = 0;
				pthread_mutex_unlock(&gMonLock);
			}
			else if (soft)
			{
				// 只有电流恢复（其它硬条件仍成立）：容忍 TRMON_GRACE_SEC 秒抖动
				pthread_mutex_lock(&gMonLock);
				if (gMonStuckSec > 0)
				{
					gMonGraceSec += TRMON_SAMPLE_SEC;
					if (gMonGraceSec > TRMON_GRACE_SEC)
					{
						gMonStuckSec = 0;
						gMonGraceSec = 0;
					}
				}
				pthread_mutex_unlock(&gMonLock);
			}
			else
			{
				// 未在充电/满电/高温/读不到：立即清零
				pthread_mutex_lock(&gMonLock);
				gMonStuckSec = 0;
				gMonGraceSec = 0;
				pthread_mutex_unlock(&gMonLock);
			}

			if (reason.length > 0 && !stuck)
				TRMonSetNote([NSString stringWithFormat:@"[%@] %@", mode, reason]);

			// 恢复正常充电 → 熔断计数归零（「连续」才熔断）
			if (powered && !stuck && !soft)
			{
				NSDictionary *st0 = TRMonitorStateLoad();
				if ([st0[@"breaker"] integerValue] > 0)
				{
					NSMutableDictionary *m0 = [st0 mutableCopy];
					m0[@"breaker"] = @0;
					TRMonitorStateWrite(m0);
					TRAppendLog(@"daemon.log", @"[monitor] 恢复正常充电，熔断计数已归零");
				}
			}

			NSDictionary *live = TRMonLive();
			double stuckSec = [live[@"stuckSec"] doubleValue];
			TRMonSetNote(stuck ? [NSString stringWithFormat:@"卡死样 已累计 %ld 秒 / 需 %ld 秒",
			                                             (long)stuckSec, (long)need]
			                   : (soft && stuckSec > 0
			                          ? [NSString stringWithFormat:@"电流短时恢复，容忍中（%ld 秒 / 需 %ld 秒）",
			                                                       (long)stuckSec, (long)need]
			                          : [NSString stringWithFormat:@"不满足：%@", reason ?: @"?"]));

			if (stuck && stuckSec >= need)
			{
				NSDictionary *st = TRMonitorStateLoad();
				double boot = TRMonitorCurrentBootTime();
				NSMutableDictionary *st2 = [st mutableCopy];

				if (boot > 0 && fabs([st2[@"bootTS"] doubleValue] - boot) > 1.0)
				{
					// 新的一次开机：次数归零，熔断与历史时间戳保留（不会被重启覆盖）
					st2[@"bootTS"] = @(boot);
					st2[@"rebootCountBoot"] = @0;
					TRMonitorStateWrite(st2);
				}

				NSString *block = TRMonitorSafetyBlock(st2);
				if (block != nil)
				{
					TRMonSetNote([NSString stringWithFormat:@"条件成立但被安全约束挡住：%@", block]);
					TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"[monitor] 拦下：%@", block]);
				}
				else
				{
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

					TRAppendLog(@"daemon.log", [NSString stringWithFormat:
						@"[monitor] ✅ 条件成立（连续 %ld 秒 / 需 %ld 分钟 / 电量 %@%% / 电流 %@mA），执行 reboot(0)",
						(long)stuckSec, (long)minutes, sample[@"percent"] ?: @"?", sample[@"currentMA"] ?: @"?"]);
					sleep(1);
					sync();
					reboot(0);
					TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"[monitor] reboot(0) failed errno=%d", errno]);
				}
			}

			sleep(TRMON_SAMPLE_SEC);
		}
	}
	return NULL;
}

static NSString *TRMonitorJSON(void)
{
	NSDictionary *live = TRMonLive();
	NSDictionary *st = TRMonitorStateLoad();

	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	out[@"ok"] = @YES;
	out[@"minutes"] = @(TRMonitorStuckMinutes());
	out[@"stuckSec"] = live[@"stuckSec"] ?: @0;
	out[@"note"] = live[@"note"] ?: @"";
	out[@"conditions"] = TRMonitorConditionsText();
	out[@"state"] = st;
	out[@"bootTS"] = @(TRMonitorCurrentBootTime());
	// 给 UI 标红用：安全约束原因 / 熔断次数 / 近 1 小时与 24 小时次数
	NSString *block = TRMonitorSafetyBlock(st);
	out[@"blocked"] = block ?: @"";
	out[@"breaker"] = st[@"breaker"] ?: @0;

	double now = (double)time(NULL);
	NSInteger perHour = 0, perDay = 0;
	for (NSNumber *n in (st[@"rebootTimes"] ?: @[]))
	{
		double dt = now - [n doubleValue];
		if (dt <= 86400.0)
			perDay++;
		if (dt <= 3600.0)
			perHour++;
	}
	out[@"perHour"] = @(perHour);
	out[@"perDay"] = @(perDay);

	NSData *d = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
	return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
	         : @"{\"ok\":false}";
}

/// /monitor/set?minutes=N —— 唯一可写项。返回 JSON，便于 App 端确认「真的写进去了」
static NSString *TRMonitorSetMinutes(NSString *query)
{
	NSInteger before = TRMonitorStuckMinutesFromFile();
	NSInteger minutes = before;

	NSRange qm = [query rangeOfString:@"minutes="];
	if (qm.location != NSNotFound)
		minutes = [[query substringFromIndex:NSMaxRange(qm)] integerValue];
	if (minutes < TRMON_MINUTES_MIN)
		minutes = TRMON_MINUTES_MIN;
	if (minutes > TRMON_MINUTES_MAX)
		minutes = TRMON_MINUTES_MAX;

	NSString *detail = nil;
	BOOL ok = TRMonitorWriteStuckMinutes(minutes, &detail);
	NSInteger saved = TRMonitorStuckMinutesFromFile();

	TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"[monitor] 分钟数 %ld → 请求 %ld → 文件读回 %ld（写入 ok=%d %@）文件=%@",
	                                                      (long)before, (long)minutes, (long)saved, ok, detail ?: @"",
	                                                      TRMonitorConfigPath()]);

	NSDictionary *j = @{
		@"ok" : @(ok && saved == minutes),
		@"requested" : @(minutes),
		@"minutes" : @(saved),
		@"file" : TRMonitorConfigPath()
	};
	NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:NULL];
	return d.length ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

/// /monitor/reset —— 人工重置熔断与计数（不动分钟数）
static NSString *TRMonitorReset(void)
{
	NSMutableDictionary *st = [TRMonitorStateLoad() mutableCopy];
	st[@"breaker"] = @0;
	st[@"lastRebootTS"] = @0;
	st[@"rebootCountBoot"] = @0;
	st[@"rebootTimes"] = @[];
	st[@"bootTS"] = @(TRMonitorCurrentBootTime());
	TRMonitorStateWrite(st);

	pthread_mutex_lock(&gMonLock);
	gMonStuckSec = 0;
	pthread_mutex_unlock(&gMonLock);
	TRMonSetNote(@"已人工重置");

	TRAppendLog(@"daemon.log", @"[monitor] 已人工重置熔断与计数");
	return @"已重置（熔断/冷却/计数清零）";
}

static NSString *TRHandleRequest(NSString *path)
{
	TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"request path=%@", path]);
	TRWriteHeartbeat();

	if ([path hasPrefix:@"/monitor/reset"])
	{
		return TRMonitorReset();
	}
	if ([path hasPrefix:@"/monitor/set"])
	{
		NSString *q = @"";
		NSRange qm = [path rangeOfString:@"?"];
		if (qm.location != NSNotFound)
			q = [path substringFromIndex:NSMaxRange(qm)];
		return TRMonitorSetMinutes(q);
	}
	if ([path hasPrefix:@"/monitor"])
	{
		return TRMonitorJSON();
	}

	if ([path hasPrefix:@"/reboot"])
	{
		TRAppendLog(@"daemon.log", @"reboot(0) 即将执行");
		sync();
		reboot(0);
		TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"reboot(0) failed errno=%d", errno]);
		return [NSString stringWithFormat:@"reboot failed errno=%d", errno];
	}
	if ([path hasPrefix:@"/respring"])
	{
		TRKillSpringBoard();
		return @"respring sent";
	}
	if ([path hasPrefix:@"/uninstall-launcher"])
	{
		int lrc = TRUninstallLauncher();
		return [NSString stringWithFormat:@"uninstall-launcher rc=%d euid=%u", lrc, geteuid()];
	}
	if ([path hasPrefix:@"/install-launcher"])
	{
		int lrc = TRInstallLauncher();
		return [NSString stringWithFormat:@"install-launcher rc=%d uid=%u euid=%u", lrc, getuid(), geteuid()];
	}
	if ([path hasPrefix:@"/install-hard"])
	{
		int rc = TRInstallDaemonHard();
		return [NSString stringWithFormat:@"install-hard rc=%d euid=%u", rc, geteuid()];
	}
	if ([path hasPrefix:@"/install"])
	{
		int rc = TRInstallDaemon();
		return [NSString stringWithFormat:@"install rc=%d euid=%u", rc, geteuid()];
	}
	if ([path hasPrefix:@"/batteryjson"])
	{
		static NSString *lastGood = nil;
		NSString *raw = TRBatteryReadIsolatedWithFormat(YES);
		NSDictionary *j = nil;
		if ([raw hasPrefix:@"{"])
			j = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];

		if ([j isKindOfClass:[NSDictionary class]] && [j[@"ok"] boolValue])
		{
			lastGood = raw;
			return raw;
		}

		// IOKit 崩了：用公开电源 API 兜底，至少给电量/插电/充电，并附上上一次成功读到的电流（标注为旧值）
		NSMutableDictionary *fallback = [NSMutableDictionary dictionary];
		NSDictionary *pub = TRPowerSourcesRead();
		for (NSString *k in pub)
			fallback[k] = pub[k];
		fallback[@"ok"] = @([pub[@"ok"] boolValue]);
		fallback[@"degraded"] = @YES;
		fallback[@"iokitError"] = [raw length] > 0 ? raw : @"空响应";
		if (lastGood.length > 0)
			fallback[@"lastGood"] = lastGood;

		NSData *d = [NSJSONSerialization dataWithJSONObject:fallback options:0 error:NULL];
		return d.length ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
	}
	if ([path hasPrefix:@"/battery"])
	{
		NSString *line = TRBatteryReadIsolated();
		TRAppendLog(@"daemon.log", line);
		return line;
	}
	if ([path hasPrefix:@"/ping"] || [path isEqualToString:@"/"])
	{
		return [NSString stringWithFormat:@"ok uid=%u pid=%d", getuid(), getpid()];
	}
	return @"unknown path";
}

/// v3.6：端口被旧版守护占着（进程里跑的是旧代码，没有 /battery）时，
/// 按心跳文件里的 pid 把它杀掉——我们是 root，直接 SIGKILL。
static int TRKillStaleDaemon(void)
{
	NSString *hb = [NSString stringWithContentsOfFile:TRPath(@"heartbeat")
	                                         encoding:NSUTF8StringEncoding
	                                            error:nil];
	if (hb.length == 0)
		return -1;

	NSRange r = [hb rangeOfString:@"pid="];
	if (r.location == NSNotFound)
		return -1;

	NSString *rest = [hb substringFromIndex:NSMaxRange(r)];
	NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
	NSRange stop = [rest rangeOfCharacterFromSet:nonDigits];
	NSString *pidStr = (stop.location == NSNotFound) ? rest : [rest substringToIndex:stop.location];

	int pid = pidStr.intValue;
	if (pid <= 0 || pid == getpid())
		return -1;

	kill(pid, SIGKILL);
	TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"已杀掉旧守护实例 pid=%d（版本升级接管）", pid]);
	return pid;
}

int TRRunDaemon(void)
{
	@autoreleasepool
	{
		TREnsureBaseDir();
		TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"daemon start uid=%u euid=%u pid=%d",
			getuid(), geteuid(), getpid()]);

		// v3.4：心跳线程必须在端口抢到之后再启动，否则重复实例会在 bind 失败前先写一次心跳，
		// 造成「在线但没在听」的假象。
		pthread_t hb;

		int sfd = socket(AF_INET, SOCK_STREAM, 0);
		if (sfd < 0)
		{
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"socket failed errno=%d", errno]);
			return 1;
		}
		int one = 1;
		setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

		struct sockaddr_in addr;
		memset(&addr, 0, sizeof(addr));
		addr.sin_family = AF_INET;
		addr.sin_port = htons(TR_DAEMON_PORT);
		addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

		if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
		{
			int bindErr = errno;
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"bind %d failed errno=%d（端口被占）",
				TR_DAEMON_PORT, bindErr]);

			if (bindErr == EADDRINUSE && TRKillStaleDaemon() > 0)
			{
				sleep(1);
				if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) == 0)
				{
					TRAppendLog(@"daemon.log", @"接管成功（旧实例已退出）");
				}
				else
				{
					TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"接管失败 errno=%d", errno]);
					close(sfd);
					return 2;
				}
			}
			else
			{
				close(sfd);
				return 2;
			}
		}
		if (listen(sfd, 8) < 0)
		{
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"listen failed errno=%d", errno]);
			close(sfd);
			return 3;
		}

		TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"listening on 127.0.0.1:%d", TR_DAEMON_PORT]);
		TRWriteHeartbeat();
		pthread_create(&hb, NULL, TRHeartbeatThread, NULL);

		// v3.5-mon：充电卡死监控线程（默认关闭，配置在 monitor.conf）
		pthread_t mon;
		if (pthread_create(&mon, NULL, TRMonitorThread, NULL) == 0)
		{
			pthread_detach(mon);
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"[monitor] 线程已启动：连续 %ld 分钟｜%@",
			                                                      (long)TRMonitorStuckMinutesFromFile(),
			                                                      TRMonitorConditionsText()]);
		}

		for (;;)
		{
			int cfd = accept(sfd, NULL, NULL);
			if (cfd < 0) continue;

			char buf[1024];
			ssize_t n = read(cfd, buf, sizeof(buf) - 1);
			NSString *reply = @"bad request";
			if (n > 0)
			{
				buf[n] = '\0';
				NSString *head = [NSString stringWithUTF8String:buf];
				NSArray *parts = [head componentsSeparatedByString:@" "];
				if (parts.count >= 2) reply = TRHandleRequest(parts[1]);
			}
			TRRespond(cfd, 200, reply);
			close(cfd);
		}
	}
	return 0;
}

/// v3.6：先杀掉旧版守护再重新起（App 发现 /battery 返回 unknown path 时调用），
/// 避免「端口被旧进程占着 → 新代码永远拿不到端口」的死结。
int TRRunDaemonRestart(void)
{
	TRKillStaleDaemon();
	sleep(1);
	return TRRunDaemon();
}

#pragma mark - plist 生成

static NSString *TRDaemonPlistText(NSString *exe)
{
	return [NSString stringWithFormat:
		@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		@"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
		@"<plist version=\"1.0\"><dict>\n"
		@"<key>Label</key><string>%s</string>\n"
		@"<key>ProgramArguments</key><array><string>%@</string><string>--daemon</string></array>\n"
		@"<key>UserName</key><string>root</string>\n"
		@"<key>RunAtLoad</key><true/>\n"
		@"<key>KeepAlive</key><true/>\n"
		@"<key>ThrottleInterval</key><integer>10</integer>\n"
		@"<key>ProcessType</key><string>Interactive</string>\n"
		@"<key>StandardOutPath</key><string>%@</string>\n"
		@"<key>StandardErrorPath</key><string>%@</string>\n"
		@"</dict></plist>\n", TR_DAEMON_LABEL, exe, TRPath(@"stdout.log"), TRPath(@"stderr.log")];
}

#pragma mark - 诊断：挂载表 + 可写探测

NSString *TRPathsProbe(void)
{
	NSMutableString *m = [NSMutableString string];

	struct statfs *mnts = NULL;
	int n = getmntinfo(&mnts, MNT_NOWAIT);
	[m appendString:@"--- 挂载点 ---\n"];
	for (int i = 0; i < n && i < 14; i++)
	{
		[m appendFormat:@"%s  (%s)  flags=0x%x%s\n",
			mnts[i].f_mntonname, mnts[i].f_fstypename, mnts[i].f_flags,
			(mnts[i].f_flags & MNT_RDONLY) ? "  [只读]" : ""];
	}

	[m appendString:@"--- 可写探测 ---\n"];
	NSArray *paths = @[@"/Library/LaunchDaemons", @"/System/Library/LaunchDaemons",
	                   @"/usr/libexec", @"/Applications", @"/var/mobile/Library/Caches"];
	for (NSString *dir in paths)
	{
		BOOL isDir = NO;
		BOOL exist = [[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir];
		NSString *probe = [dir stringByAppendingPathComponent:@".trprobe"];
		errno = 0;
		BOOL ok = [@"x" writeToFile:probe atomically:NO encoding:NSUTF8StringEncoding error:nil];
		int e = errno;
		if (ok) [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
		[m appendFormat:@"%@  存在=%@  可写=%@  errno=%d(%s)\n",
			dir, exist ? @"Y" : @"N", ok ? @"Y" : @"N", e, strerror(e)];
	}
	return m;
}
NSString *TRSystemAppsProbe(void)
{
	NSMutableString *m = [NSMutableString string];
	NSFileManager *fm = [NSFileManager defaultManager];

	[m appendString:@"--- 可替换系统App (/private/var/containers) ---\n"];
	NSString *root = @"/private/var/containers/Bundle/Application";
	NSArray *containers = [fm contentsOfDirectoryAtPath:root error:nil];
	if (containers.count == 0) [m appendString:@"(读不到，可能权限不足)\n"];

	for (NSString *c in containers)
	{
		NSString *appDir = [root stringByAppendingPathComponent:c];
		NSArray *inners = [fm contentsOfDirectoryAtPath:appDir error:nil];
		for (NSString *inner in inners)
		{
			if (![inner hasSuffix:@".app"]) continue;
			NSString *bundle = [appDir stringByAppendingPathComponent:inner];
			NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
				[bundle stringByAppendingPathComponent:@"Info.plist"]];
			NSString *bid = info[@"CFBundleIdentifier"] ?: @"?";
			NSString *exe = info[@"CFBundleExecutable"] ?: @"?";
			BOOL marked = [fm fileExistsAtPath:[bundle stringByAppendingPathComponent:@".TrollStorePersistenceHelper"]];
			BOOL backup = [fm fileExistsAtPath:[bundle stringByAppendingPathComponent:
				[exe stringByAppendingString:@"_TROLLSTORE_BACKUP"]]];
			BOOL helper = [fm fileExistsAtPath:[bundle stringByAppendingPathComponent:@"trollstorehelper"]];
			[m appendFormat:@"%@\n  exe=%@ 巨魔标记=%@ 原件备份=%@ helper=%@\n",
				bid, exe, marked ? @"Y" : @"N", backup ? @"Y" : @"N", helper ? @"Y" : @"N"];
		}
	}

	[m appendString:@"--- 只读系统App (/Applications) ---\n"];
	NSArray *apps = [fm contentsOfDirectoryAtPath:@"/Applications" error:nil];
	for (NSString *a in apps)
	{
		if (![a hasSuffix:@".app"]) continue;
		[m appendFormat:@"%@\n", a];
	}
	return m;
}
#pragma mark - 安装 / 卸载

static BOOL TRWritePlist(NSString *plist, NSString *path, NSString **detail)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSError *err = nil;

	// 目录不存在就建（/Library/LaunchDaemons 在干净系统里可能不存在）
	NSString *dir = [path stringByDeletingLastPathComponent];
	if (![fm fileExistsAtPath:dir])
	{
		[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	}

	if (![plist writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err])
	{
		if (detail) *detail = [NSString stringWithFormat:@"写 %@ 失败: %@", path, err.localizedDescription];
		return NO;
	}
	[fm setAttributes:@{NSFilePosixPermissions: @0644,
	                    NSFileOwnerAccountName: @"root",
	                    NSFileGroupOwnerAccountName: @"wheel"}
	     ofItemAtPath:path error:nil];
	if (detail) *detail = [NSString stringWithFormat:@"plist 已写入 %@", path];
	return YES;
}

/// 把自身可执行文件复制到稳定的系统路径（不依赖 App 容器路径，App 更新也不影响）
static NSString *TRInstallBinaryCopy(NSString **detail)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *src = [NSBundle mainBundle].executablePath;
	if (src.length == 0)
	{
		if (detail) *detail = @"拿不到自身可执行路径";
		return nil;
	}

	NSError *err = nil;
	if ([fm fileExistsAtPath:@TR_DAEMON_BIN])
	{
		// 已存在就先覆盖；覆盖失败则看旧文件能不能用
		if (![fm removeItemAtPath:@TR_DAEMON_BIN error:nil])
		{
			if ([fm isExecutableFileAtPath:@TR_DAEMON_BIN])
			{
				if (detail) *detail = [NSString stringWithFormat:@"沿用已存在的 %s", TR_DAEMON_BIN];
				return @TR_DAEMON_BIN;
			}
		}
	}

	if (![fm copyItemAtPath:src toPath:@TR_DAEMON_BIN error:&err])
	{
		if (detail) *detail = [NSString stringWithFormat:@"复制到 %s 失败：%@", TR_DAEMON_BIN, err.localizedDescription];
		return nil;
	}
	[fm setAttributes:@{NSFilePosixPermissions: @0755,
	                    NSFileOwnerAccountName: @"root",
	                    NSFileGroupOwnerAccountName: @"wheel"}
	     ofItemAtPath:@TR_DAEMON_BIN error:nil];

	if (detail) *detail = [NSString stringWithFormat:@"守护二进制已就位：%s (%llu bytes)",
		TR_DAEMON_BIN, [[fm attributesOfItemAtPath:@TR_DAEMON_BIN error:nil][NSFileSize] unsignedLongLongValue]];
	return @TR_DAEMON_BIN;
}
/// 进程内直接 mount(2) 重挂根分区（不依赖 /sbin/mount，也不受它自己的沙箱限制）
static NSString *TRRemountRootInProcess(void)
{
	struct statfs *mnts = NULL;
	int n = getmntinfo(&mnts, MNT_NOWAIT);
	if (n <= 0)
		return [NSString stringWithFormat:@"getmntinfo 失败 errno=%d (%s)", errno, strerror(errno)];

	for (int i = 0; i < n; i++)
	{
		if (strcmp(mnts[i].f_mntonname, "/") != 0) continue;
		if (!(mnts[i].f_flags & MNT_RDONLY))
			return @"根分区本来就是可写的";

		struct statfs fs = mnts[i];
		if (mount(mnts[i].f_fstypename, "/", MNT_UPDATE, &fs) == 0)
			return @"mount(2) 重挂成功：/ 已可写";
		return [NSString stringWithFormat:@"mount(2) 重挂失败 errno=%d (%s)  [根分区 %s, flags=0x%x]",
			errno, strerror(errno), mnts[i].f_fstypename, mnts[i].f_flags];
	}
	return @"没找到挂载点 /";
}
/// 尝试把根文件系统挂回可写，返回日志
static NSString *TRRemountRoot(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *candidates = @[@"/sbin/mount", @"/usr/bin/mount", @"/bin/mount"];
	NSString *log = nil;

	for (NSString *tool in candidates)
	{
		if (![fm fileExistsAtPath:tool]) continue;
		TRRunCmd(tool, @[@"-u", @"-o", @"rw", @"/"], &log);
		return log ?: [NSString stringWithFormat:@"执行了 %@ 但无输出", tool];
	}
	return @"系统里没有 mount 命令（/sbin/mount、/usr/bin/mount 都不存在），无法重挂根分区";
}

int TRInstallDaemon(void)
{
	@autoreleasepool
	{
		TREnsureBaseDir();
		TRAppendLog(@"install.log", @"========== install start ==========");
		TRAppendLog(@"install.log", [NSString stringWithFormat:@"uid=%u euid=%u", getuid(), geteuid()]);

		if (geteuid() != 0)
		{
			TRAppendLog(@"install.log", @"NOT ROOT：必须以 root 运行 --install-daemon");
			return 2;
		}

		TRAppendLog(@"install.log", TRPathsProbe());

		NSString *binDetail = nil;
		NSString *bin = TRInstallBinaryCopy(&binDetail);
		TRAppendLog(@"install.log", binDetail ?: @"");
		if (!bin)
		{
			bin = [NSBundle mainBundle].executablePath;
			TRAppendLog(@"install.log", [NSString stringWithFormat:
				@"⚠️ 复制到 /usr/libexec 失败，退回用 App 自身路径：%@", bin]);
		}
		if (bin.length == 0) return 3;

		NSFileManager *fm = [NSFileManager defaultManager];
		BOOL hasLaunchctl = [fm fileExistsAtPath:@TR_LAUNCHCTL];
		NSString *plist = TRDaemonPlistText(bin);
		NSString *detail = nil;
		NSString *log = nil;

		// ---- 第一步：/Library/LaunchDaemons ----
		BOOL wroteLib = TRWritePlist(plist, @TR_DAEMON_PLIST, &detail);
		TRAppendLog(@"install.log", detail ?: @"");

		int rc = -1;
		if (hasLaunchctl)
		{
			rc = TRRunCmd(@TR_LAUNCHCTL, @[@"print", @"system"], &log);
			TRAppendLog(@"install.log", log);
			if (rc == 0 && wroteLib)
			{
				rc = TRRunCmd(@TR_LAUNCHCTL, @[@"bootstrap", @"system", @TR_DAEMON_PLIST], &log);
				TRAppendLog(@"install.log", log);
				if (rc != 0)
				{
					rc = TRRunCmd(@TR_LAUNCHCTL, @[@"load", @"-w", @TR_DAEMON_PLIST], &log);
					TRAppendLog(@"install.log", log);
				}
			}
			else if (rc != 0)
			{
				TRAppendLog(@"install.log", rc == -1
					? @"探测结论：/bin/launchctl 存在，但一执行就被 SIGHUP 杀掉（rc=-1）→ 干净 iOS 上不可用，改由 launchd 开机扫 plist"
					: [NSString stringWithFormat:@"探测结论：launchctl print system rc=%d，跳过 bootstrap", rc]);
			}
		}
		else
		{
			TRAppendLog(@"install.log", @"系统无 /bin/launchctl → 由 launchd 开机自己扫 plist");
		}

		TRAppendLog(@"install.log", [NSString stringWithFormat:@"结果(软)：/Library=%@  launchctl rc=%d",
			wroteLib ? @"OK" : @"失败", rc]);

		// ---- 第二步：launchctl 不可用就自动升级为写系统盘（launchd 开机只扫 /System）----
		if (rc != 0 || !wroteLib)
		{
			TRAppendLog(@"install.log", @"---- 自动升级：写 /System/Library/LaunchDaemons ----");
			int hardRc = TRInstallDaemonHard();
			return hardRc == 0 ? 0 : 7;
		}

		TRAppendLog(@"install.log", @"✅ 已用 launchctl 登记，守护现在就应该在跑（不用重启）");
		return 0;
	}
}

int TRInstallDaemonHard(void)
{
	@autoreleasepool
	{
		TREnsureBaseDir();
		TRAppendLog(@"install.log", @"========== hard install (/System) ==========");

		if (geteuid() != 0)
		{
			TRAppendLog(@"install.log", @"NOT ROOT：必须以 root 运行 --install-daemon-hard");
			return 2;
		}

		NSString *binDetail = nil;
		NSString *bin = TRInstallBinaryCopy(&binDetail);
		TRAppendLog(@"install.log", binDetail ?: @"");
		if (!bin)
		{
			bin = [NSBundle mainBundle].executablePath;
			TRAppendLog(@"install.log", [NSString stringWithFormat:
				@"⚠️ 复制到 /usr/libexec 失败，退回用 App 自身路径：%@", bin]);
		}
		if (bin.length == 0) return 3;

		NSString *plist = TRDaemonPlistText(bin);
		NSString *detail = nil;

		BOOL wroteSys = TRWritePlist(plist, @TR_SYSTEM_PLIST, &detail);
		if (!wroteSys)
		{
			TRAppendLog(@"install.log", [NSString stringWithFormat:@"首次写 /System 失败：%@", detail ?: @""]);
			TRAppendLog(@"install.log", @"---- 重挂根分区为可写 ----");
			NSString *remount = TRRemountRootInProcess();
			TRAppendLog(@"install.log", remount);
			// 进程内 mount(2) 不行再退回外部命令
			if (![remount hasPrefix:@"mount(2) 重挂成功"] && ![remount isEqualToString:@"根分区本来就是可写的"])
			{
				TRAppendLog(@"install.log", TRRemountRoot());
			}
			wroteSys = TRWritePlist(plist, @TR_SYSTEM_PLIST, &detail);
		}
		TRAppendLog(@"install.log", detail ?: @"");
		TRWritePlist(plist, @TR_DAEMON_PLIST, &detail);

		TRAppendLog(@"install.log", [NSString stringWithFormat:@"结果(硬)：/System=%@",
			wroteSys ? @"OK" : @"失败"]);

		if (wroteSys)
			TRAppendLog(@"install.log", @"✅ 已就位 /System/Library/LaunchDaemons + /usr/libexec/TrollRebootDaemon —— 重启手机后 launchd 自动加载，之后不用开 App、不用点按钮");
		else
			TRAppendLog(@"install.log", @"❌ 系统分区写不进去（只读且重挂失败），只能走「打开 URL 自动化」");

		return wroteSys ? 0 : 6;
	}
}

int TRUninstallDaemon(void)
{
	@autoreleasepool
	{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *label = [NSString stringWithFormat:@"system/%s", TR_DAEMON_LABEL];
		NSString *log = nil;

		if ([fm fileExistsAtPath:@TR_LAUNCHCTL])
		{
			TRRunCmd(@TR_LAUNCHCTL, @[@"bootout", label], &log);
			TRAppendLog(@"install.log", log ?: @"bootout");
			TRRunCmd(@TR_LAUNCHCTL, @[@"unload", @"-w", @TR_DAEMON_PLIST], &log);
			TRAppendLog(@"install.log", log ?: @"unload");
		}

		[fm removeItemAtPath:@TR_DAEMON_PLIST error:nil];
		[fm removeItemAtPath:@TR_SYSTEM_PLIST error:nil];
		TRAppendLog(@"install.log", @"已删除 /Library 与 /System 两处 plist");
		return 0;
	}
}

#pragma mark - 状态

NSDictionary<NSString *, id> *TRDaemonStatus(void)
{
	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	NSString *hb = [NSString stringWithContentsOfFile:TRPath(@"heartbeat") encoding:NSUTF8StringEncoding error:nil];
	out[@"heartbeat"] = hb ?: @"";
	if (hb)
	{
		NSRange r = [hb rangeOfString:@"ts="];
		if (r.location != NSNotFound)
		{
			long long ts = [[hb substringFromIndex:NSMaxRange(r)] longLongValue];
			long long age = (long long)time(NULL) - ts;
			out[@"age"] = @(age);
			out[@"online"] = @(age >= 0 && age < 20);
		}
	}
	NSFileManager *fm = [NSFileManager defaultManager];
	out[@"plistExists"] = @([fm fileExistsAtPath:@TR_DAEMON_PLIST]);
	out[@"systemPlistExists"] = @([fm fileExistsAtPath:@TR_SYSTEM_PLIST]);
	out[@"binExists"] = @([fm fileExistsAtPath:@TR_DAEMON_BIN]);
	return out;
}

static NSString *TRTail(NSString *path, NSUInteger lines)
{
	NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	if (!text.length) return @"(空)";
	NSArray *all = [text componentsSeparatedByString:@"\n"];
	NSUInteger from = all.count > lines ? all.count - lines : 0;
	return [[all subarrayWithRange:NSMakeRange(from, all.count - from)] componentsJoinedByString:@"\n"];
}

NSString *TRDaemonLogTail(NSUInteger lines) { return TRTail(TRPath(@"daemon.log"), lines); }
NSString *TRInstallLogTail(NSUInteger lines) { return TRTail(TRPath(@"install.log"), lines); }
NSString *TRLauncherLogTail(NSUInteger lines) { return TRTail(TRPath(@"launcher.log"), lines); }

#pragma mark - 用自身拉起 root 进程

static int TRSpawnSelf(NSArray<NSString *> *args, BOOL detached)
{
	NSString *exe = [NSBundle mainBundle].executablePath;
	NSString *outString = nil;
	NSString *errString = nil;
	int rc;

	if (detached) rc = TRSpawnRootDetached(exe, args, &outString, &errString);
	else rc = TRSpawnRoot(exe, args, &outString, &errString);

	if (rc != 0)
	{
		TRAppendLog(@"install.log", [NSString stringWithFormat:@"spawn self %@ rc=%d %@",
			[args componentsJoinedByString:@" "], rc, errString ?: @""]);
	}
	return rc;
}

void TRAppendInstallLog(NSString *text)
{
	TRAppendLog(@"install.log", text ?: @"");
}
NSString *TRDaemonRequest(NSString *path)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) return [NSString stringWithFormat:@"socket errno=%d", errno];

	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(TR_DAEMON_PORT);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0)
	{
		int e = errno;
		close(fd);
		return [NSString stringWithFormat:@"connect errno=%d", e];
	}
	NSString *req = [NSString stringWithFormat:
		@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", path];
	const char *bytes = req.UTF8String;
	write(fd, bytes, strlen(bytes));

	NSMutableData *d = [NSMutableData data];
	char b[2048];
	ssize_t n;
	while ((n = read(fd, b, sizeof(b))) > 0) [d appendBytes:b length:(NSUInteger)n];
	close(fd);

	NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
	if (!s) return @"(无响应)";
	NSRange r = [s rangeOfString:@"\r\n\r\n"];
	if (r.location != NSNotFound) return [s substringFromIndex:r.location + r.length];
	return s;
}
int TRLaunchDaemonDetached(void)
{
	return TRSpawnSelf(@[@"--daemon"], YES);
}

/// v3.6：杀掉旧版守护并用新代码重起（端口被旧进程占着时的自救）
int TRRestartDaemonDetached(void)
{
	return TRSpawnSelf(@[@"--daemon-restart"], YES);
}

int TRInstallDaemonViaRoot(void)
{
	int rc = TRSpawnSelf(@[@"--install-daemon"], NO);
	if (rc != 0)
	{
		TRAppendLog(@"install.log", [NSString stringWithFormat:
			@"阻塞式 spawn 失败 rc=%d，改用分离进程（同「① 启用后台守护」）重试", rc]);
		rc = TRSpawnSelf(@[@"--install-daemon"], YES);
	}
	return rc;
}

int TRInstallDaemonHardViaRoot(void)
{
	int rc = TRSpawnSelf(@[@"--install-daemon-hard"], NO);
	if (rc != 0)
	{
		TRAppendLog(@"install.log", [NSString stringWithFormat:
			@"阻塞式 spawn 失败 rc=%d，改用分离进程重试（硬安装）", rc]);
		rc = TRSpawnSelf(@[@"--install-daemon-hard"], YES);
	}
	return rc;
}

int TRUninstallDaemonViaRoot(void)
{
	return TRSpawnSelf(@[@"--uninstall-daemon"], NO);
}


#pragma mark - v3.2 开机启动器（TrollStore 持久化助手式，宿主优先 Watch）

static NSString *const TRLauncherMarkerName = @".TrollRebootLauncher";
static NSString *const TRLauncherBackupSuffix = @"_TROLLSTORE_BACKUP";
static NSString *const TRTrollStoreMarkerName = @".TrollStorePersistenceHelper";

/// 候选宿主，按优先级：Watch(com.apple.Bridge) 为主；Tips 保留用于还原上一版
static NSArray<NSString *> *TRLauncherHostBids(void)
{
	return @[@"com.apple.Bridge", @"com.apple.tips"];
}

/// 在 /private/var/containers/Bundle/Application 下按 bundle id 找 App 目录
static NSString *TRFindBundleByIdentifier(NSString *bid)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *root = @"/private/var/containers/Bundle/Application";
	for (NSString *c in [fm contentsOfDirectoryAtPath:root error:nil])
	{
		NSString *dir = [root stringByAppendingPathComponent:c];
		for (NSString *inner in [fm contentsOfDirectoryAtPath:dir error:nil])
		{
			if (![inner hasSuffix:@".app"]) continue;
			NSString *bundle = [dir stringByAppendingPathComponent:inner];
			NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
				[bundle stringByAppendingPathComponent:@"Info.plist"]];
			if ([info[@"CFBundleIdentifier"] isEqualToString:bid]) return bundle;
		}
	}
	return nil;
}

static NSString *TRBundleExePath(NSString *bundle)
{
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
		[bundle stringByAppendingPathComponent:@"Info.plist"]];
	NSString *exeName = info[@"CFBundleExecutable"];
	if (exeName.length == 0) exeName = [[bundle lastPathComponent] stringByDeletingPathExtension];
	return [bundle stringByAppendingPathComponent:exeName];
}

static NSString *TRBundleBid(NSString *bundle)
{
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
		[bundle stringByAppendingPathComponent:@"Info.plist"]];
	return info[@"CFBundleIdentifier"] ?: [bundle lastPathComponent];
}

static BOOL TRBundleHasOurMarker(NSString *bundle)
{
	return [[NSFileManager defaultManager] fileExistsAtPath:
		[bundle stringByAppendingPathComponent:TRLauncherMarkerName]];
}

static BOOL TRBundleIsTrollStoreHost(NSString *bundle)
{
	return [[NSFileManager defaultManager] fileExistsAtPath:
		[bundle stringByAppendingPathComponent:TRTrollStoreMarkerName]];
}

/// 选宿主：已装过的优先；否则取第一个存在、且没被 TrollStore 占用的
static NSString *TRPickLauncherBundle(NSMutableArray<NSString *> *notes)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *bids = TRLauncherHostBids();

	for (NSString *bid in bids)
	{
		NSString *b = TRFindBundleByIdentifier(bid);
		if (b && TRBundleHasOurMarker(b)) return b;
	}

	for (NSString *bid in bids)
	{
		NSString *b = TRFindBundleByIdentifier(bid);
		if (!b)
		{
			if (notes) [notes addObject:[NSString stringWithFormat:@"%@ 找不到", bid]];
			continue;
		}
		if ([fm fileExistsAtPath:[b stringByAppendingPathComponent:TRTrollStoreMarkerName]])
		{
			if (notes) [notes addObject:[NSString stringWithFormat:@"%@ 已被 TrollStore 占用，跳过", bid]];
			continue;
		}
		if (notes) [notes addObject:[NSString stringWithFormat:@"选中 %@", bid]];
		return b;
	}
	return nil;
}

BOOL TRIsLauncherHost(void)
{
	NSString *exe = [NSBundle mainBundle].executablePath;
	if (exe.length == 0) return NO;
	return TRBundleHasOurMarker([exe stringByDeletingLastPathComponent]);
}

int TRRunLauncher(int argc, char *argv[])
{
	@autoreleasepool
	{
		NSString *exe = [NSBundle mainBundle].executablePath;
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:
			@"启动器被系统拉起 exe=%@ pid=%d uid=%u euid=%u argc=%d",
			exe, getpid(), getuid(), geteuid(), argc]);

		// 1) 先起 root 守护（分离进程，不阻塞本进程）；已在跑就跳过，避免多实例抢端口
		int rc = 0;
		if (TRDaemonIsOnline())
		{
			TRAppendLog(@"launcher.log", @"守护已在跑，跳过 spawn");
		}
		else
		{
			rc = TRSpawnRootDetached(exe, @[@"--daemon"], NULL, NULL);
			TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"spawn --daemon rc=%d (%s)",
				rc, rc == 0 ? "ok" : strerror(rc)]);
		}

		// 2) 把控制权交还原 App
		NSString *backup = [exe stringByAppendingString:TRLauncherBackupSuffix];
		if ([[NSFileManager defaultManager] isExecutableFileAtPath:backup])
		{
			execv(backup.fileSystemRepresentation, argv);
			TRAppendLog(@"launcher.log", [NSString stringWithFormat:
				@"execv(%@) 失败 errno=%d (%s)", backup, errno, strerror(errno)]);
		}
		else
		{
			TRAppendLog(@"launcher.log", @"没有原件备份，直接退出（被替换的 App 将打不开）");
		}
	}
	return 0;
}

static int TRRestoreLauncherAt(NSString *bundle)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *bid = TRBundleBid(bundle);
	NSString *exe = TRBundleExePath(bundle);
	NSString *backup = [exe stringByAppendingString:TRLauncherBackupSuffix];
	NSString *marker = [bundle stringByAppendingPathComponent:TRLauncherMarkerName];

	if (!TRBundleHasOurMarker(bundle))
	{
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"%@ 不是我们的宿主（无标记），跳过", bid]);
		return 0;
	}
	if (TRBundleIsTrollStoreHost(bundle))
	{
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"%@ 带 TrollStore 标记，拒绝改动", bid]);
		return 0;
	}
	if (![fm fileExistsAtPath:backup])
	{
		[fm removeItemAtPath:marker error:nil];
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"%@ 没有原件备份，只清掉标记", bid]);
		return 0;
	}

	[fm removeItemAtPath:exe error:nil];
	NSError *err = nil;
	if (![fm moveItemAtPath:backup toPath:exe error:&err])
	{
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"%@ 还原失败：%@", bid, err.localizedDescription]);
		return 13;
	}
	[fm removeItemAtPath:marker error:nil];
	[fm setAttributes:@{NSFilePosixPermissions: @0755,
	                    NSFileOwnerAccountID: @501,
	                    NSFileGroupOwnerAccountID: @501}
	     ofItemAtPath:exe error:nil];
	TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"%@ 已还原原件", bid]);
	return 0;
}

int TRInstallLauncher(void)
{
	@autoreleasepool
	{
		NSFileManager *fm = [NSFileManager defaultManager];
		TRAppendLog(@"launcher.log", @"----------- install launcher -----------");
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:
			@"install enter uid=%u euid=%u gid=%u pid=%d", getuid(), geteuid(), getegid(), getpid()]);

		NSMutableArray *notes = [NSMutableArray array];
		NSString *bundle = TRPickLauncherBundle(notes);
		for (NSString *n in notes) TRAppendLog(@"launcher.log", n);
		if (!bundle)
		{
			TRAppendLog(@"launcher.log", @"❌ 没有可用宿主（候选都找不到或被 TrollStore 占用）");
			return 11;
		}

		NSString *bid = TRBundleBid(bundle);
		NSString *exe = TRBundleExePath(bundle);
		NSString *backup = [exe stringByAppendingString:TRLauncherBackupSuffix];
		NSString *marker = [bundle stringByAppendingPathComponent:TRLauncherMarkerName];
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"目标宿主 %@ → %@", bid, bundle]);

		if (TRBundleHasOurMarker(bundle))
		{
			TRAppendLog(@"launcher.log", @"已装过（标记存在），跳过");
			return 0;
		}
		if (TRBundleIsTrollStoreHost(bundle))
		{
			TRAppendLog(@"launcher.log", @"❌ 该宿主带 TrollStore 标记，拒绝改动");
			return 16;
		}
		if ([fm fileExistsAtPath:backup])
		{
			TRAppendLog(@"launcher.log", @"❌ 已存在原件备份（可能被别的助手占用），中止");
			return 12;
		}
		if (![fm fileExistsAtPath:exe])
		{
			TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"❌ 主可执行文件不存在：%@", exe]);
			return 13;
		}

		NSError *err = nil;

		// 写权限探针：能否在宿主 bundle 目录里建文件（区分「没权限」与「路径不对」）
		NSString *probePath = [bundle stringByAppendingPathComponent:@".trwrite"];
		NSError *probeErr = nil;
		BOOL probed = [@"x" writeToFile:probePath atomically:YES
		                       encoding:NSUTF8StringEncoding error:&probeErr];
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"探针 写 %@ = %@%@",
			probePath, probed ? @"OK" : @"失败",
			probed ? @"" : [NSString stringWithFormat:@" (errno=%d %@)",
				errno, probeErr.localizedDescription]]);
		if (probed) [fm removeItemAtPath:probePath error:nil];

		BOOL moved = NO;
		errno = 0;
		if (rename(exe.fileSystemRepresentation, backup.fileSystemRepresentation) == 0)
		{
			moved = YES;
			TRAppendLog(@"launcher.log", @"备份：rename() 成功");
		}
		else
		{
			int e1 = errno;
			TRAppendLog(@"launcher.log", [NSString stringWithFormat:
				@"rename() 失败 errno=%d (%s)，改用 moveItemAtPath", e1, strerror(e1)]);
			if ([fm moveItemAtPath:exe toPath:backup error:&err])
			{
				moved = YES;
				TRAppendLog(@"launcher.log", @"备份：moveItemAtPath 成功");
			}
			else
			{
				TRAppendLog(@"launcher.log", [NSString stringWithFormat:
					@"❌ 备份原件失败：%@ (NSFileManagerCode=%ld errno=%d %s)",
					err.localizedDescription, (long)err.code, errno, strerror(errno)]);
			}
		}
		if (!moved) return 14;
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"1/3 原件已改名备份 → %@", backup]);

		NSString *src = [NSBundle mainBundle].executablePath;
		if (src.length == 0 || ![fm copyItemAtPath:src toPath:exe error:&err])
		{
			[fm removeItemAtPath:exe error:nil];
			[fm moveItemAtPath:backup toPath:exe error:nil];
			TRAppendLog(@"launcher.log", [NSString stringWithFormat:
				@"❌ 复制启动器失败，已回滚：%@", err.localizedDescription]);
			return 15;
		}
		TRAppendLog(@"launcher.log", @"2/3 启动器已就位（宿主主可执行已被替换）");

		[fm setAttributes:@{NSFilePosixPermissions: @0755,
		                    NSFileOwnerAccountID: @501,
		                    NSFileGroupOwnerAccountID: @501}
		     ofItemAtPath:exe error:nil];

		[@"trollreboot launcher" writeToFile:marker atomically:YES
		                          encoding:NSUTF8StringEncoding error:nil];
		[fm setAttributes:@{NSFilePosixPermissions: @0644,
		                    NSFileOwnerAccountID: @501,
		                    NSFileGroupOwnerAccountID: @501}
		     ofItemAtPath:marker error:nil];

		[[bid dataUsingEncoding:NSUTF8StringEncoding] writeToFile:TRPath(@"launcher.target") atomically:YES];

		TRAppendLog(@"launcher.log", [NSString stringWithFormat:
			@"3/3 标记已写入（宿主=%@）→ 之后系统拉起该 App 时会自动起守护", bid]);
		TRAppendLog(@"launcher.log", @"install launcher done rc=0");
	}
	return 0;
}

int TRUninstallLauncher(void)
{
	@autoreleasepool
	{
		TRAppendLog(@"launcher.log", @"----------- uninstall launcher -----------");

		// 先按记录的宿主还原，再把候选列表全扫一遍（兼容上一版装在 Tips 的情况）
		NSString *recorded = [NSString stringWithContentsOfFile:TRPath(@"launcher.target")
		                                              encoding:NSUTF8StringEncoding error:nil];
		recorded = [recorded stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

		NSMutableArray *bids = [NSMutableArray array];
		if (recorded.length) [bids addObject:recorded];
		for (NSString *b in TRLauncherHostBids()) if (![bids containsObject:b]) [bids addObject:b];

		int rc = 0;
		for (NSString *bid in bids)
		{
			NSString *bundle = TRFindBundleByIdentifier(bid);
			if (!bundle) continue;
			if (!TRBundleHasOurMarker(bundle)) continue;
			int r = TRRestoreLauncherAt(bundle);
			if (r != 0) rc = r;
		}
		[[NSFileManager defaultManager] removeItemAtPath:TRPath(@"launcher.target") error:nil];
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"uninstall launcher rc=%d", rc]);
		return rc;
	}
}

int TRLauncherInstallViaRoot(void)
{
	// 优先交给已在跑的 root 守护（uid 0 常驻进程，少一层 spawn 变量）
	NSString *viaDaemon = TRDaemonRequest(@"/install-launcher");
	TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"请求守护安装 → %@", viaDaemon]);
	if ([viaDaemon containsString:@"rc=0"]) return 0;

	int rc = TRSpawnSelf(@[@"--install-launcher"], NO);
	if (rc != 0)
	{
		TRAppendLog(@"launcher.log", [NSString stringWithFormat:
			@"阻塞式 spawn 失败 rc=%d，改用分离进程重试", rc]);
		rc = TRSpawnSelf(@[@"--install-launcher"], YES);
	}
	return rc;
}

int TRLauncherUninstallViaRoot(void)
{
	NSString *viaDaemon = TRDaemonRequest(@"/uninstall-launcher");
	TRAppendLog(@"launcher.log", [NSString stringWithFormat:@"请求守护还原 → %@", viaDaemon]);
	if ([viaDaemon containsString:@"rc=0"]) return 0;
	return TRSpawnSelf(@[@"--uninstall-launcher"], NO);
}

NSString *TRLauncherStatusText(void)
{
	NSMutableString *m = [NSMutableString string];
	NSFileManager *fm = [NSFileManager defaultManager];

	for (NSString *bid in TRLauncherHostBids())
	{
		NSString *bundle = TRFindBundleByIdentifier(bid);
		if (!bundle)
		{
			[m appendFormat:@"宿主 %@ = 找不到\n", bid];
			continue;
		}
		NSString *exe = TRBundleExePath(bundle);
		NSString *backup = [exe stringByAppendingString:TRLauncherBackupSuffix];
		BOOL ours = TRBundleHasOurMarker(bundle);
		BOOL ts = TRBundleIsTrollStoreHost(bundle);
		unsigned long long exeSize =
			[[fm attributesOfItemAtPath:exe error:nil][NSFileSize] unsignedLongLongValue];
		unsigned long long bakSize =
			[[fm attributesOfItemAtPath:backup error:nil][NSFileSize] unsignedLongLongValue];

		[m appendFormat:@"宿主 %@\n", bid];
		[m appendFormat:@"  我们的标记=%@%@  原件备份=%@\n",
			ours ? @"是 ✅" : @"否",
			ts ? @"  (带 TrollStore 标记)" : @"",
			bakSize > 0 ? [NSString stringWithFormat:@"是 (%llu B)", bakSize] : @"无"];
		[m appendFormat:@"  当前主可执行=%llu B%@\n", exeSize,
			(ours && bakSize > 0 && exeSize != bakSize) ? @"  (已被替换为启动器)" : @""];
	}
	return m;
}

BOOL TRDaemonIsOnline(void)
{
	return [TRDaemonStatus()[@"online"] boolValue];
}

int TREnsureDaemonDetached(void)
{
	if (TRDaemonIsOnline())
	{
		TRAppendLog(@"daemon.log", @"已有守护在跑（心跳新鲜），跳过 spawn");
		return 0;
	}
	int rc = TRSpawnSelf(@[@"--daemon"], YES);
	TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"守护不在跑，自动补起 rc=%d (%s)",
		rc, rc == 0 ? "ok" : strerror(rc)]);
	return rc;
}
