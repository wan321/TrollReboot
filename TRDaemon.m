#import "TRDaemon.h"
#import "TRRootOps.h"

#include <spawn.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
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

static NSString *TRHandleRequest(NSString *path)
{
	TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"request path=%@", path]);
	TRWriteHeartbeat();

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
	if ([path hasPrefix:@"/ping"] || [path isEqualToString:@"/"])
	{
		return [NSString stringWithFormat:@"ok uid=%u pid=%d", getuid(), getpid()];
	}
	return @"unknown path";
}

int TRRunDaemon(void)
{
	@autoreleasepool
	{
		TREnsureBaseDir();
		TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"daemon start uid=%u euid=%u pid=%d",
			getuid(), geteuid(), getpid()]);

		pthread_t hb;
		pthread_create(&hb, NULL, TRHeartbeatThread, NULL);

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
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"bind %d failed errno=%d（可能已有实例在跑）",
				TR_DAEMON_PORT, errno]);
			close(sfd);
			TRWriteHeartbeat();
			return 2;
		}
		if (listen(sfd, 8) < 0)
		{
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"listen failed errno=%d", errno]);
			close(sfd);
			return 3;
		}

		TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"listening on 127.0.0.1:%d", TR_DAEMON_PORT]);
		TRWriteHeartbeat();

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

		NSString *exe = [NSBundle mainBundle].executablePath;
		if (exe.length == 0)
		{
			TRAppendLog(@"install.log", @"拿不到自身可执行路径");
			return 3;
		}
		TRAppendLog(@"install.log", [NSString stringWithFormat:@"exe=%@", exe]);

		NSFileManager *fm = [NSFileManager defaultManager];
		BOOL hasLaunchctl = [fm fileExistsAtPath:@TR_LAUNCHCTL];
		TRAppendLog(@"install.log", hasLaunchctl
			? @"检测到 /bin/launchctl，可用命令登记作业"
			: @"系统无 /bin/launchctl（干净 iOS 不带它）→ 改为把 plist 放到位，交给 launchd 开机自己扫");

		NSString *plist = TRDaemonPlistText(exe);
		NSString *detail = nil;
		NSString *log = nil;

		// ---- 软安装：只写 /Library/LaunchDaemons，不碰系统分区 ----
		BOOL wroteLib = TRWritePlist(plist, @TR_DAEMON_PLIST, &detail);
		TRAppendLog(@"install.log", detail ?: @"");

		int rc = -1;
		if (hasLaunchctl && wroteLib)
		{
			rc = TRRunCmd(@TR_LAUNCHCTL, @[@"bootstrap", @"system", @TR_DAEMON_PLIST], &log);
			TRAppendLog(@"install.log", log);
			if (rc != 0)
			{
				rc = TRRunCmd(@TR_LAUNCHCTL, @[@"load", @"-w", @TR_DAEMON_PLIST], &log);
				TRAppendLog(@"install.log", log);
			}
		}
		else if (!hasLaunchctl)
		{
			TRAppendLog(@"install.log", @"跳过 launchctl（本机没有）");
		}

		TRAppendLog(@"install.log", [NSString stringWithFormat:@"结果(软)：/Library=%@  launchctl rc=%d",
			wroteLib ? @"OK" : @"失败", rc]);

		if (wroteLib)
			TRAppendLog(@"install.log", @"✅ 已做软安装：重启后看守护是否自己起来；没起来再点「写系统盘」");
		else
			TRAppendLog(@"install.log", @"❌ 连 /Library 都没写进去，请把上面报错发我");

		return wroteLib ? 0 : 5;
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

		NSString *exe = [NSBundle mainBundle].executablePath;
		if (exe.length == 0) return 3;

		NSFileManager *fm = [NSFileManager defaultManager];
		BOOL hasLaunchctl = [fm fileExistsAtPath:@TR_LAUNCHCTL];
		NSString *plist = TRDaemonPlistText(exe);
		NSString *detail = nil;
		NSString *log = nil;

		// ---- 硬安装：重挂根分区写入 /System/Library/LaunchDaemons ----
		BOOL wroteSys = TRWritePlist(plist, @TR_SYSTEM_PLIST, &detail);
		if (!wroteSys)
		{
			TRAppendLog(@"install.log", [NSString stringWithFormat:@"首次写 /System 失败：%@", detail ?: @""]);
			TRAppendLog(@"install.log", @"---- 重挂根分区为可写 ----");
			TRAppendLog(@"install.log", TRRemountRoot());
			wroteSys = TRWritePlist(plist, @TR_SYSTEM_PLIST, &detail);
		}
		TRAppendLog(@"install.log", detail ?: @"");

		int rc = -1;
		if (hasLaunchctl && wroteSys)
		{
			rc = TRRunCmd(@TR_LAUNCHCTL, @[@"bootstrap", @"system", @TR_SYSTEM_PLIST], &log);
			TRAppendLog(@"install.log", log);
		}

		TRAppendLog(@"install.log", [NSString stringWithFormat:@"结果(硬)：/System=%@  launchctl rc=%d",
			wroteSys ? @"OK" : @"失败", rc]);

		if (wroteSys)
			TRAppendLog(@"install.log", @"✅ 已写入 /System/Library/LaunchDaemons —— 重启手机后 launchd 会自己加载它");
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

int TRLaunchDaemonDetached(void)
{
	return TRSpawnSelf(@[@"--daemon"], YES);
}

int TRInstallDaemonViaRoot(void)
{
	return TRSpawnSelf(@[@"--install-daemon"], NO);
}

int TRInstallDaemonHardViaRoot(void)
{
	return TRSpawnSelf(@[@"--install-daemon-hard"], NO);
}

int TRUninstallDaemonViaRoot(void)
{
	return TRSpawnSelf(@[@"--uninstall-daemon"], NO);
}
