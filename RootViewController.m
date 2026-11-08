#import "RootViewController.h"
#import "TRRootOps.h"
#import "TRDaemon.h"

#include <unistd.h>

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
	self.titleLabel.text = @"TrollReboot 3.1";
	self.titleLabel.font = [UIFont boldSystemFontOfSize:28];
	[self.view addSubview:self.titleLabel];

	self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 84, w - pad * 2, 54)];
	self.hintLabel.numberOfLines = 0;
	self.hintLabel.font = [UIFont systemFontOfSize:11];
	self.hintLabel.textColor = [UIColor secondaryLabelColor];
	self.hintLabel.text = @"v3.1 用 TrollStore 持久化助手的同一机制：把「提示(Tips)」的启动器换成我们，系统每次拉起 Tips 时先起 root 守护。\n点 ② 安装（原件自动备份）→ 重启手机 → 解锁后不用开 App。\n锁屏触发：快捷指令「获取 URL 内容」访问 http://127.0.0.1:8899/reboot";
	[self.view addSubview:self.hintLabel];

	self.daemonButton = [self makeButton:@"① 启用后台守护（当前开机周期内生效）" y:142 color:[UIColor systemBlueColor]];
	[self.daemonButton addTarget:self action:@selector(enableDaemonTapped) forControlEvents:UIControlEventTouchUpInside];

	self.autostartButton = [self makeButton:@"② 装开机启动器（用 Tips 当宿主）" y:190 color:[UIColor systemIndigoColor]];
	[self.autostartButton addTarget:self action:@selector(launcherInstallTapped) forControlEvents:UIControlEventTouchUpInside];

	[self makeSmallButton:@"还原 Tips" x:pad y:242 action:@selector(restoreTipsTapped)];
	[self makeSmallButton:@"刷新" x:pad + 92 y:242 action:@selector(refreshTapped)];
	[self makeSmallButton:@"复制状态" x:pad + 164 y:242 action:@selector(copyTapped)];

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

	// v3.1：不再自动装 launchd 作业（本机根卷只读，此路已证死），
	// 也不再把「现在拉起守护」当兜底（用户明确否决）。开机自启改由 ② 启动器负责。

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
	[m appendFormat:@"build = TrollReboot 3.1\n"];
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

- (void)copyTapped { [UIPasteboard generalPasteboard].string = self.statusView.text ?: @""; }

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
	[self appendLog:@"--- 安装开机启动器（把 Tips 的主可执行换成我们，原件改名备份）---"];

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
	[self appendLog:@"--- 还原 Tips 原件 ---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int rc = TRLauncherUninstallViaRoot();
		sleep(1);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			[self appendLog:rc == 0
				? @"✅ 已还原（Tips 恢复原样，开机启动器失效）"
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
