#import "RootViewController.h"
#import "TRRootOps.h"
#import "TRDaemon.h"
#import "TRBattery.h"

#include <unistd.h>
#include <time.h>

@interface RootViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *daemonButton;
@property (nonatomic, strong) UIButton *autostartButton;
@property (nonatomic, strong) UIButton *rebootButton;
@property (nonatomic, strong) UITextView *statusView;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL didAutoStart;
@property (nonatomic, strong) NSURL *pendingURL;

// v3.5-probe：只读充电探针
@property (nonatomic, strong) UIButton *probeButton;
@property (nonatomic, strong) UITextView *probeView;
@property (nonatomic, strong) NSTimer *probeTimer;
@property (nonatomic, strong) NSMutableArray<NSString *> *probeLines;
@property (nonatomic, assign) BOOL probing;
@property (nonatomic, assign) NSInteger probeTicks;
@property (nonatomic, assign) time_t probeStart;
@end

@implementation RootViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor systemBackgroundColor];
	[self buildUI];
	[self appendLog:[NSString stringWithFormat:@"启动完成 · uid=%u euid=%u", getuid(), geteuid()]];
}

- (void)buildUI
{
	CGFloat w = self.view.bounds.size.width;
	CGFloat pad = 16.0;

	self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 48, w - pad * 2, 36)];
	self.titleLabel.text = @"TrollReboot 3.5-probe2";
	self.titleLabel.font = [UIFont boldSystemFontOfSize:28];
	[self.view addSubview:self.titleLabel];

	self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 84, w - pad * 2, 54)];
	self.hintLabel.numberOfLines = 0;
	self.hintLabel.font = [UIFont systemFontOfSize:11];
	self.hintLabel.textColor = [UIColor secondaryLabelColor];
	self.hintLabel.text = @"本版只加「充电探针」：每秒读一次电池（私有 IOKit / AppleSmartBattery），只显示不动作，绝不会重启。\n插电、拔电各看几行，确认电流/电压/温度能不能读到、符号正不正。\n探针数据同时写进 Documents/charge-probe.log，可点「复制状态」整段发我。";
	[self.view addSubview:self.hintLabel];

	self.daemonButton = [self makeButton:@"① 启用后台守护（当前开机周期内生效）" y:142 color:[UIColor systemBlueColor]];
	[self.daemonButton addTarget:self action:@selector(enableDaemonTapped) forControlEvents:UIControlEventTouchUpInside];

	self.autostartButton = [self makeButton:@"② 装开机启动器（用 Watch 当宿主）" y:190 color:[UIColor systemIndigoColor]];
	[self.autostartButton addTarget:self action:@selector(launcherInstallTapped) forControlEvents:UIControlEventTouchUpInside];

	[self makeSmallButton:@"还原宿主" x:pad y:242 action:@selector(restoreTipsTapped)];
	[self makeSmallButton:@"刷新" x:pad + 92 y:242 action:@selector(refreshTapped)];
	[self makeSmallButton:@"复制状态" x:pad + 164 y:242 action:@selector(copyTapped)];
	self.probeButton = [self makeSmallButton:@"充电探针" x:pad + 250 y:242 action:@selector(probeTapped)];
	[self.probeButton setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];

	self.rebootButton = [self makeButton:@"立即重启（Kernel Reboot）" y:278 color:[UIColor systemRedColor]];
	[self.rebootButton addTarget:self action:@selector(rebootTapped) forControlEvents:UIControlEventTouchUpInside];

	CGFloat top = 334;
	self.statusView = [[UITextView alloc] initWithFrame:CGRectMake(pad, top, w - pad * 2, self.view.bounds.size.height - top - 16)];
	self.statusView.backgroundColor = [UIColor secondarySystemBackgroundColor];
	self.statusView.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
	self.statusView.editable = NO;
	self.statusView.selectable = YES;
	self.statusView.layer.cornerRadius = 10;
	self.statusView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
	self.statusView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self.view addSubview:self.statusView];

	// v3.5-probe：探针面板（默认隐藏，点「充电探针」才出现）
	self.probeView = [[UITextView alloc] initWithFrame:CGRectMake(pad, top, w - pad * 2, 170)];
	self.probeView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
	self.probeView.font = [UIFont monospacedSystemFontOfSize:9.0 weight:UIFontWeightRegular];
	self.probeView.editable = NO;
	self.probeView.selectable = YES;
	self.probeView.layer.cornerRadius = 10;
	self.probeView.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
	self.probeView.hidden = YES;
	self.probeView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:self.probeView];
}

- (UIButton *)makeButton:(NSString *)title y:(CGFloat)y color:(UIColor *)color
{
	CGFloat w = self.view.bounds.size.width;
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	b.frame = CGRectMake(16, y, w - 32, 44);
	b.backgroundColor = color;
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
	b.layer.cornerRadius = 11;
	b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:b];
	return b;
}

- (UIButton *)makeSmallButton:(NSString *)title x:(CGFloat)x y:(CGFloat)y action:(SEL)action
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	b.frame = CGRectMake(x, y, 84, 28);
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:13];
	[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:b];
	return b;
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	[self refreshStatus];

	// v3.4（用户 2026-11-08 批准 ③）：打开 App 时若守护没在跑，静默补起一次。
	// 不在页面上弹窗、不打断，只写一行日志；已在跑则完全不动作。
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		BOOL wasOnline = TRDaemonIsOnline();
		int rc = 0;
		if (!wasOnline)
		{
			rc = TREnsureDaemonDetached();
		sleep(2);
		}
		BOOL online = TRDaemonIsOnline();
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			if (wasOnline)
				[self appendLog:@"守护已在跑（无需拉起）"];
			else if (online)
				[self appendLog:@"打开 App 时守护不在跑，已自动补起"];
			else
				[self appendLog:[NSString stringWithFormat:@"自动补起没成功 rc=%d，看 daemon.log", rc]];
		});
	});

	if (self.pendingURL)
	{
		NSURL *url = self.pendingURL;
		self.pendingURL = nil;
		[self handleIncomingURL:url];
	}
}

- (void)refreshStatus
{
	NSMutableString *m = [NSMutableString string];
	[m appendFormat:@"build = TrollReboot 3.5-probe2\n"];
	[m appendFormat:@"app uid=%u euid=%u\n", getuid(), geteuid()];

	[m appendString:@"\n"];
	[m appendString:TRLauncherStatusText()];

	NSDictionary *st = TRDaemonStatus();
	NSString *hb = st[@"heartbeat"];
	NSNumber *age = st[@"age"];
	BOOL online = [st[@"online"] boolValue];
	[m appendFormat:@"daemon 在线=%@  (%@)\n", online ? @"是 ✅" : @"否 ❌",
		hb.length ? [hb stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]] : @"无心跳"];
	if (age) [m appendFormat:@"心跳年龄=%@s\n", age];
	[m appendFormat:@"plist  /Library=%@  /System=%@\n",
		[st[@"plistExists"] boolValue] ? @"在" : @"无",
		[st[@"systemPlistExists"] boolValue] ? @"在" : @"无"];
	[m appendFormat:@"守护二进制 /usr/libexec=%@\n", [st[@"binExists"] boolValue] ? @"在" : @"无"];
	[m appendFormat:@"端点 http://127.0.0.1:8899/reboot\n"];

	NSArray *candidates = TRHelperCandidates();
	[m appendFormat:@"trollstorehelper 候选=%lu\n", (unsigned long)candidates.count];
	for (NSString *c in candidates) [m appendFormat:@"  ✔ %@\n", c];

	[m appendString:@"\n"];
	[m appendString:TRPathsProbe()];
	[m appendString:TRSystemAppsProbe()];
	[m appendString:@"\n--- install.log 尾部 ---\n"];
	[m appendString:TRInstallLogTail(10)];
	[m appendString:@"\n--- launcher.log 尾部 ---\n"];
	[m appendString:TRLauncherLogTail(14)];
	[m appendString:@"\n--- daemon.log 尾部 ---\n"];
	[m appendString:TRDaemonLogTail(8)];

	self.statusView.text = m;
	[self.statusView scrollRangeToVisible:NSMakeRange(self.statusView.text.length, 0)];

	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	[[[NSString stringWithFormat:@"[%@]\n%@\n", [NSDate date], m] dataUsingEncoding:NSUTF8StringEncoding]
		writeToFile:[dir stringByAppendingPathComponent:@"reboot.log"] atomically:YES];
}

- (void)appendLog:(NSString *)text
{
	NSMutableString *m = [NSMutableString stringWithString:self.statusView.text ?: @""];
	[m appendFormat:@"%@\n", text];
	self.statusView.text = m;
	[self.statusView scrollRangeToVisible:NSMakeRange(self.statusView.text.length, 0)];
}

- (void)refreshTapped { [self refreshStatus]; }

- (void)copyTapped
{
	NSMutableString *all = [NSMutableString string];
	if (self.probeView.text.length > 0)
	{
		[all appendString:@"=== 充电探针（只读）===\n"];
		[all appendString:self.probeView.text];
		[all appendString:@"\n\n"];
	}
	[all appendString:self.statusView.text ?: @""];
	[UIPasteboard generalPasteboard].string = all;
}

#pragma mark - v3.5-probe 只读充电探针

- (void)probeTapped
{
	if (self.probing)
	{
		[self stopProbe];
		return;
	}
	[self startProbe];
}

- (void)startProbe
{
	self.probing = YES;
	self.probeTicks = 0;
	self.probeStart = time(NULL);
	self.probeLines = [NSMutableArray array];
	[self.probeButton setTitle:@"停止探针" forState:UIControlStateNormal];

	CGFloat pad = 16.0;
	CGFloat w = self.view.bounds.size.width;
	CGFloat top = 334.0;
	CGFloat probeH = 170.0;
	self.probeView.hidden = NO;
	self.probeView.frame = CGRectMake(pad, top, w - pad * 2, probeH);
	self.statusView.frame = CGRectMake(pad, top + probeH + 8, w - pad * 2,
	                                   self.view.bounds.size.height - (top + probeH + 8) - 16);
	self.probeView.text = @"(第 1 秒采样中…)";

	TRProbeLogAppend([NSString stringWithFormat:@"===== probe start %@", [NSDate date]]);
	[self probeTick];

	self.probeTimer = [NSTimer timerWithTimeInterval:1.0
	                                          target:self
	                                        selector:@selector(probeTick)
	                                        userInfo:nil
	                                         repeats:YES];
	self.probeTimer.tolerance = 0.15;
	[[NSRunLoop mainRunLoop] addTimer:self.probeTimer forMode:NSRunLoopCommonModes];
}

- (void)stopProbe
{
	if (!self.probing)
		return;
	self.probing = NO;
	[self.probeTimer invalidate];
	self.probeTimer = nil;
	[self.probeButton setTitle:@"充电探针" forState:UIControlStateNormal];

	CGFloat pad = 16.0;
	CGFloat w = self.view.bounds.size.width;
	CGFloat top = 334.0;
	self.probeView.hidden = YES;
	self.statusView.frame = CGRectMake(pad, top, w - pad * 2,
	                                   self.view.bounds.size.height - top - 16);

	TRProbeLogAppend(@"===== probe stop");
	[self refreshStatus];
}

- (void)probeTick
{
	if (!self.probing)
		return;

	self.probeTicks++;
	NSInteger tick = self.probeTicks;

	// v3.5-probe2：电池数据只在 root 守护进程里读（App 进程里直接碰私有 IOKit 会闪退），
	// App 侧只通过 HTTP 向 127.0.0.1:8899/battery 取一行文本。
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSString *body = TRDaemonRequest(@"/battery");
		NSString *text = [[body ?: @"" stringByTrimmingCharactersInSet:
		                  [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];

		BOOL offline = (text.length == 0) || [text isEqualToString:@"(无响应)"] || [text hasPrefix:@"connect"];
		BOOL stale = [text isEqualToString:@"unknown path"];

		if (stale || offline)
		{
			// 端口被旧版守护占着（旧代码没有 /battery），或者守护根本没在跑：杀掉旧实例起新的，再试一次
			TRRestartDaemonDetached();
			sleep(2);
			NSString *retry = TRDaemonRequest(@"/battery");
			text = [[retry ?: @"" stringByTrimmingCharactersInSet:
			         [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
			stale = [text isEqualToString:@"unknown path"];
			offline = (text.length == 0) || [text isEqualToString:@"(无响应)"] || [text hasPrefix:@"connect"];
		}

		NSString *line;
		if (offline)
			line = [NSString stringWithFormat:@"#%ld ❌ 守护没响应（先点「① 启用后台守护」，或看 daemon.log）", (long)tick];
		else if (stale)
			line = [NSString stringWithFormat:@"#%ld ❌ 旧版守护没有 /battery，已尝试重启守护，请再点一次「充电探针」", (long)tick];
		else
			line = [NSString stringWithFormat:@"#%ld %@", (long)tick, text];

		// 每秒都落盘（fsync），重启/崩溃也不丢采样
		TRProbeLogAppend(line);

		dispatch_async(dispatch_get_main_queue(), ^{
			if (!self.probing)
				return;
			[self.probeLines addObject:line];
			if (self.probeLines.count > 150)
				[self.probeLines removeObjectAtIndex:0];

			NSString *elapsed = [NSString stringWithFormat:
				@"探针中 · 已 %ld 秒 · 数据来自 root 守护 /battery · 日志 Documents/charge-probe.log",
				(long)(time(NULL) - self.probeStart)];
			NSString *bodyText = [self.probeLines componentsJoinedByString:@"\n"];
			self.probeView.text = [NSString stringWithFormat:@"%@\n%@", elapsed, bodyText];
			[self.probeView scrollRangeToVisible:NSMakeRange(self.probeView.text.length, 0)];
		});
	});
}

- (void)enableDaemonTapped
{
	if (self.busy) return;
	self.busy = YES;
	self.daemonButton.enabled = NO;
	[self appendLog:@"--- 启用后台守护（分离进程）---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int rc = TRLaunchDaemonDetached();
		sleep(2);
		BOOL online = [TRDaemonStatus()[@"online"] boolValue];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			[self appendLog:online
				? @"✅ 守护已在线（当前开机周期内有效，重启后需自启）"
				: [NSString stringWithFormat:@"❌ 没起来 rc=%d，看 install.log", rc]];
			self.busy = NO;
			self.daemonButton.enabled = YES;
		});
	});
}

- (void)launcherInstallTapped
{
	if (self.busy) return;
	self.busy = YES;
	self.autostartButton.enabled = NO;
	[self appendLog:@"--- 安装开机启动器（把宿主 Watch 的主可执行换成我们，原件改名备份）---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int rc = TRLauncherInstallViaRoot();
		sleep(1);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			if (rc == 0)
				[self appendLog:@"✅ 启动器已安装。现在重启手机，然后只解锁（不打开任何 App）等 30 秒，看心跳是否刷新。"];
			else
				[self appendLog:[NSString stringWithFormat:@"❌ 安装失败 rc=%d，看下面 launcher.log", rc]];
			self.busy = NO;
			self.autostartButton.enabled = YES;
		});
	});
}

- (void)restoreTipsTapped
{
	if (self.busy) return;
	self.busy = YES;
	[self appendLog:@"--- 还原宿主原件 ---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int rc = TRLauncherUninstallViaRoot();
		sleep(1);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			[self appendLog:rc == 0
				? @"✅ 已还原（宿主恢复原样，开机启动器失效）"
				: [NSString stringWithFormat:@"❌ 还原失败 rc=%d，看下面 launcher.log", rc]];
			self.busy = NO;
		});
	});
}
- (void)uninstallTapped
{
	if (self.busy) return;
	self.busy = YES;
	[self appendLog:@"--- 移除开机自启 ---"];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		TRUninstallDaemonViaRoot();
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			[self appendLog:@"已移除 launchd 作业与 plist（当前进程仍在跑）"];
			self.busy = NO;
		});
	});
}

- (void)rebootTapped
{
	if (self.busy) return;
	self.busy = YES;
	self.rebootButton.enabled = NO;
	[self appendLog:@"--- 用户点击重启 ---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *log = nil;
		TRRequestReboot(&log);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self appendLog:log ?: @"(无日志)"];
			self.busy = NO;
			self.rebootButton.enabled = YES;
		});
	});
}

- (void)handleIncomingURL:(NSURL *)url
{
	if (!self.isViewLoaded)
	{
		self.pendingURL = url;
		return;
	}

	NSString *scheme = url.scheme.lowercaseString;
	[self appendLog:[NSString stringWithFormat:@"收到 URL: %@", url.absoluteString]];

	BOOL schemeOK = [scheme isEqualToString:@"trollreboot"] || [scheme isEqualToString:@"reboottools"];
	if (!schemeOK)
	{
		[self appendLog:[NSString stringWithFormat:@"忽略 scheme=%@", scheme]];
		return;
	}
	[self rebootTapped];
}

@end
