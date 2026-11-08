#import "TRDaemon.h"
#import "TRRootOps.h"

#include <spawn.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
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
#include <sys/reboot.h>

#define TR_DAEMON_PORT   8899
#define TR_DAEMON_LABEL  "com.wan.trollreboot.daemon"
#define TR_DAEMON_PLIST  "/Library/LaunchDaemons/com.wan.trollreboot.daemon.plist"

static NSString *const TRBaseDirPath = @"/var/mobile/Library/Caches/com.wan.trollreboot";

static const char *ctimeString(void);

static NSString *TRPath(NSString *name)
{
	return [TRBaseDirPath stringByAppendingPathComponent:name];
}

static void TREnsureBaseDir(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createDirectoryAtPath:TRBaseDirPath withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
}

static void TRAppendLog(NSString *name, NSString *text)
{
	TREnsureBaseDir();
	NSString *path = TRPath(name);
	NSString *line = [NSString stringWithFormat:@"[%s] %@\n", ctimeString(), text];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	NSFileManager *fm = [NSFileManager defaultManager];

	// 超过 128KB 就清空，避免无限增长
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
	time_t t = time(NULL);
	struct tm tmv;
	localtime_r(&t, &tmv);
	strftime(buf, sizeof(buf), "%H:%M:%S", &tmv);
	return buf;
}

static void TRWriteHeartbeat(void)
{
	TREnsureBaseDir();
	NSString *text = [NSString stringWithFormat:@"uid=%u euid=%u pid=%d ts=%ld\n",
		getuid(), geteuid(), getpid(), (long)time(NULL)];
	[[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:TRPath(@"heartbeat") atomically:YES];
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
		char name[2 * MAXCOMLEN + 1] = {0};
		strlcpy(name, info[i].kp_proc.p_comm, sizeof(name));
		if (strcmp(name, "SpringBoard") == 0)
		{
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"respring: kill(%d, SIGTERM)", pid]);
			kill(pid, SIGTERM);
		}
	}
	free(info);
}

#pragma mark - heartbeat thread

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

#pragma mark - HTTP server

static void TRRespond(int fd, int code, NSString *body)
{
	NSString *resp = [NSString stringWithFormat:
		@"HTTP/1.1 %d %@\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
		code, code == 200 ? @"OK" : @"ERR", (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding], body];
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
		TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"daemon start uid=%u euid=%u pid=%d", getuid(), geteuid(), getpid()]);

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
			TRAppendLog(@"daemon.log", [NSString stringWithFormat:@"bind %d failed errno=%d", TR_DAEMON_PORT, errno]);
			close(sfd);
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
				if (parts.count >= 2)
				{
					reply = TRHandleRequest(parts[1]);
				}
			}
			TRRespond(cfd, 200, reply);
			close(cfd);
		}
	}
	return 0;
}

#pragma mark - install

int TRInstallDaemon(void)
{
	@autoreleasepool
	{
		TREnsureBaseDir();
		TRAppendLog(@"install.log", [NSString stringWithFormat:@"install start uid=%u euid=%u", getuid(), geteuid()]);

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

		NSString *plist = [NSString stringWithFormat:
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

		NSError *err = nil;
		if (![plist writeToFile:@TR_DAEMON_PLIST atomically:YES encoding:NSUTF8StringEncoding error:&err])
		{
			TRAppendLog(@"install.log", [NSString stringWithFormat:@"写 plist 失败: %@", err.localizedDescription]);
			return 4;
		}

		NSFileManager *fm = [NSFileManager defaultManager];
		[fm setAttributes:@{NSFilePosixPermissions: @0644, NSFileOwnerAccountName: @"root", NSFileGroupOwnerAccountName: @"wheel"} ofItemAtPath:@TR_DAEMON_PLIST error:nil];
		TRAppendLog(@"install.log", @"plist 已写入 /Library/LaunchDaemons");

		// 先尝试 bootstrap（iOS 14 上 /bin/launchctl 存在）
		int rc = TRSpawnRoot(@"/bin/launchctl", @[@"bootstrap", @"system", @TR_DAEMON_PLIST], nil, nil);
		TRAppendLog(@"install.log", [NSString stringWithFormat:@"launchctl bootstrap rc=%d", rc]);

		if (rc != 0)
		{
			rc = TRSpawnRoot(@"/bin/launchctl", @[@"load", @"-w", @TR_DAEMON_PLIST], nil, nil);
			TRAppendLog(@"install.log", [NSString stringWithFormat:@"launchctl load rc=%d", rc]);
		}

		TRAppendLog(@"install.log", [NSString stringWithFormat:@"install done rc=%d", rc]);
		return rc;
	}
}

#pragma mark - status helpers

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
	out[@"plistExists"] = @([[NSFileManager defaultManager] fileExistsAtPath:@TR_DAEMON_PLIST]);
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

#pragma mark - spawn self as root

static int TRSpawnSelf(NSArray<NSString *> *args, BOOL detached, NSString **log)
{
	NSString *exe = [NSBundle mainBundle].executablePath;
	NSMutableString *m = [NSMutableString string];
	[m appendFormat:@"exe=%@\n", exe];

	NSString *outString = nil;
	NSString *errString = nil;
	int rc = 0;

	if (detached)
	{
		rc = TRSpawnRootDetached(exe, args, &outString, &errString);
		[m appendFormat:@"detached spawn rc=%d\n", rc];
	}
	else
	{
		rc = TRSpawnRoot(exe, args, &outString, &errString);
		[m appendFormat:@"spawn rc=%d\n", rc];
	}
	if (outString.length) [m appendFormat:@"stdout=%@\n", outString];
	if (errString.length) [m appendFormat:@"stderr=%@\n", errString];
	if (log) *log = [m copy];
	return rc;
}

int TRLaunchDaemonDetached(void)
{
	NSString *log = nil;
	return TRSpawnSelf(@[@"--daemon"], YES, &log);
}

int TRInstallDaemonViaRoot(void)
{
	NSString *log = nil;
	int rc = TRSpawnSelf(@[@"--install-daemon"], NO, &log);
	return rc;
}
