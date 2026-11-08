#import "TRRootOps.h"

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

// 读管道直到 EOF。每个管道一个独立队列，避免交替读取造成的阻塞死锁。
static void TRDrainPipe(int fd, NSMutableString *dst, dispatch_semaphore_t sema)
{
	char buf[1024];
	ssize_t n;
	while ((n = read(fd, buf, sizeof(buf))) > 0)
	{
		@autoreleasepool
		{
			NSString *chunk = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
			if (chunk)
			{
				[dst appendString:chunk];
			}
		}
	}
	close(fd);
	dispatch_semaphore_signal(sema);
}

int TRSpawnRoot(NSString *path, NSArray<NSString *> *args, NSString **stdOut, NSString **stdErr)
{
	if (path.length == 0)
	{
		if (stdErr) *stdErr = @"empty path";
		return EINVAL;
	}

	NSMutableArray *argsM = args ? [args mutableCopy] : [NSMutableArray array];
	[argsM insertObject:path atIndex:0];

	NSUInteger argCount = argsM.count;
	char **argsC = (char **)calloc(argCount + 1, sizeof(char *));
	if (!argsC)
	{
		if (stdErr) *stdErr = @"calloc failed";
		return ENOMEM;
	}
	for (NSUInteger i = 0; i < argCount; i++)
	{
		argsC[i] = strdup([argsM[i] UTF8String]);
	}
	argsC[argCount] = NULL;

	posix_spawnattr_t attr;
	posix_spawnattr_init(&attr);
	posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
	posix_spawnattr_set_persona_uid_np(&attr, 0);
	posix_spawnattr_set_persona_gid_np(&attr, 0);

	posix_spawn_file_actions_t action;
	posix_spawn_file_actions_init(&action);

	int out[2] = {-1, -1};
	int outErr[2] = {-1, -1};

	if (stdErr && pipe(outErr) == 0)
	{
		posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
	}
	if (stdOut && pipe(out) == 0)
	{
		posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
	}

	pid_t pid = 0;
	int status = -200;
	int spawnError = posix_spawn(&pid, path.fileSystemRepresentation, &action, &attr, argsC, NULL);

	posix_spawn_file_actions_destroy(&action);
	posix_spawnattr_destroy(&attr);
	for (NSUInteger i = 0; i < argCount; i++)
	{
		free(argsC[i]);
	}
	free(argsC);

	if (spawnError != 0)
	{
		if (stdOut) *stdOut = @"";
		if (stdErr) *stdErr = [NSString stringWithFormat:@"posix_spawn=%d (%s)", spawnError, strerror(spawnError)];
		if (out[0] >= 0) { close(out[0]); close(out[1]); }
		if (outErr[0] >= 0) { close(outErr[0]); close(outErr[1]); }
		return spawnError;
	}

	NSMutableString *outString = [NSMutableString string];
	NSMutableString *errString = [NSMutableString string];
	dispatch_semaphore_t sema = dispatch_semaphore_create(0);
	int drains = 0;

	// block 里不能直接引用数组类型，先把 fd 取成标量
	int outReadFd = out[0];
	int outWriteFd = out[1];
	int errReadFd = outErr[0];
	int errWriteFd = outErr[1];

	if (stdOut && outReadFd >= 0)
	{
		close(outWriteFd);
		int fd = outReadFd;
		drains++;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			TRDrainPipe(fd, outString, sema);
		});
	}
	if (stdErr && errReadFd >= 0)
	{
		close(errWriteFd);
		int fd = errReadFd;
		drains++;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			TRDrainPipe(fd, errString, sema);
		});
	}

	do
	{
		if (waitpid(pid, &status, 0) == -1)
		{
			if (stdErr) *stdErr = [NSString stringWithFormat:@"waitpid errno=%d", errno];
			return -222;
		}
	} while (!WIFEXITED(status) && !WIFSIGNALED(status));

	for (int i = 0; i < drains; i++)
	{
		dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
	}

	if (stdOut) *stdOut = [outString copy];
	if (stdErr) *stdErr = [errString copy];

	if (WIFSIGNALED(status)) return -WTERMSIG(status);
	return WEXITSTATUS(status);
}

int TRSpawnRootDetached(NSString *path, NSArray<NSString *> *args, NSString **stdOut, NSString **stdErr)
{
	if (path.length == 0)
	{
		if (stdErr) *stdErr = @"empty path";
		return EINVAL;
	}

	NSMutableArray *argsM = args ? [args mutableCopy] : [NSMutableArray array];
	[argsM insertObject:path atIndex:0];

	NSUInteger argCount = argsM.count;
	char **argsC = (char **)calloc(argCount + 1, sizeof(char *));
	if (!argsC) return ENOMEM;
	for (NSUInteger i = 0; i < argCount; i++)
	{
		argsC[i] = strdup([argsM[i] UTF8String]);
	}
	argsC[argCount] = NULL;

	posix_spawnattr_t attr;
	posix_spawnattr_init(&attr);
	posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
	posix_spawnattr_set_persona_uid_np(&attr, 0);
	posix_spawnattr_set_persona_gid_np(&attr, 0);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

	posix_spawn_file_actions_t action;
	posix_spawn_file_actions_init(&action);
	posix_spawn_file_actions_addopen(&action, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_addopen(&action, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
	posix_spawn_file_actions_addopen(&action, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

	pid_t pid = 0;
	int spawnError = posix_spawn(&pid, path.fileSystemRepresentation, &action, &attr, argsC, NULL);

	posix_spawn_file_actions_destroy(&action);
	posix_spawnattr_destroy(&attr);
	for (NSUInteger i = 0; i < argCount; i++)
	{
		free(argsC[i]);
	}
	free(argsC);

	if (stdOut) *stdOut = @"";
	if (stdErr) *stdErr = spawnError ? [NSString stringWithFormat:@"posix_spawn=%d (%s)", spawnError, strerror(spawnError)] : @"";
	return spawnError;
}

NSArray<NSString *> *TRHelperCandidates(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray<NSString *> *list = [NSMutableArray array];

	void (^maybeAdd)(NSString *) = ^(NSString *candidate) {
		if (candidate.length == 0) return;
		if ([list containsObject:candidate]) return;
		if ([fm isExecutableFileAtPath:candidate]) [list addObject:candidate];
	};

	maybeAdd(@"/Applications/TrollStore.app/trollstorehelper");
	maybeAdd(@"/Applications/TrollStoreLite.app/trollstorehelper");

	// /Applications 下任何 App（含 TrollStore 的持久化 helper App）里的同名二进制
	NSArray *apps = [fm contentsOfDirectoryAtPath:@"/Applications" error:nil];
	for (NSString *name in apps)
	{
		if (![name hasSuffix:@".app"]) continue;
		maybeAdd([NSString pathWithComponents:@[@"/Applications", name, @"trollstorehelper"]]);
	}

	// TrollStore 2.x 装在用户容器里：/var/containers/Bundle/Application/<UUID>/TrollStore.app/
	NSArray *containers = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
	for (NSString *uuid in containers)
	{
		maybeAdd([NSString pathWithComponents:@[@"/var/containers/Bundle/Application", uuid, @"TrollStore.app", @"trollstorehelper"]]);
	}

	return list;
}

NSString *TRFindTrollStoreHelper(void)
{
	return TRHelperCandidates().firstObject;
}

BOOL TRRequestReboot(NSString **log)
{
	NSMutableString *m = [NSMutableString string];
	[m appendFormat:@"uid=%u euid=%u gid=%u\n", getuid(), geteuid(), getgid()];

	// 1) 优先用我们自己的二进制以 root 执行 reboot(0)：不调用 TrollStore 的任何代码
	NSString *selfPath = [NSBundle mainBundle].executablePath;
	if (selfPath.length)
	{
		NSString *sOut = nil;
		NSString *sErr = nil;
		int selfRc = TRSpawnRoot(selfPath, @[@"--reboot"], &sOut, &sErr);
		[m appendFormat:@"自有 --reboot: exit=%d stdout=%@ stderr=%@\n",
			selfRc,
			sOut.length ? sOut : @"(空)",
			sErr.length ? sErr : @"(空)"];
		if (selfRc == 0) { if (log) *log = [m copy]; return YES; }
	}
	else
	{
		[m appendString:@"自有 --reboot: 取不到主可执行路径\n"];
	}

	// 2) 兜底：只读执行 TrollStore 自带 trollstorehelper 的 reboot 子命令（不改它任何文件）
	[m appendString:@"→ 自有路径失败，改用 trollstorehelper 兜底\n"];
	NSString *helper = TRFindTrollStoreHelper();
	if (!helper)
	{
		[m appendString:@"未找到 trollstorehelper\n"];
		[m appendString:@"已扫描：/Applications/TrollStore.app、/Applications/*.app、/var/containers/Bundle/Application/*/TrollStore.app\n"];
		[m appendString:@"→ TrollStore 安装异常，或系统版本需要 TrollStore 2.x 容器路径\n"];
		if (log) *log = [m copy];
		return NO;
	}

	[m appendFormat:@"helper=%@\n", helper];

	NSString *outString = nil;
	NSString *errString = nil;
	int rc = TRSpawnRoot(helper, @[@"reboot"], &outString, &errString);

	[m appendFormat:@"exit=%d\n", rc];
	[m appendFormat:@"stdout=%@\n", outString.length ? outString : @"(空)"];
	[m appendFormat:@"stderr=%@\n", errString.length ? errString : @"(空)"];
	if (rc != 0)
	{
		[m appendString:@"→ 未触发重启：helper 返回非 0，看 stderr 里的 errno\n"];
	}
	if (log) *log = [m copy];
	return rc == 0;
}
