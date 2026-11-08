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
	self.titleLabel.text = @"TrollReboot 1.5";
	self.titleLabel.font = [UIFont boldSystemFontOfSize:28];
	[self.view addSubview:self.titleLabel];

	self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 84, w - pad * 2, 44)];
	self.hintLabel.numberOfLines = 0;
	self.hintLabel.font = [UIFont systemFontOfSize:11];
	self.hintLabel.textColor = [UIColor secondaryLabelColor];
	self.hintLabel.text = @"① 现在生效　② 开机自启（先软，只写 /Library；重启后没起来再点「写系统盘」）\n锁屏触发用快捷指令「获取 URL 内容」访问 http://127.0.0.1:8899/reboot";
	[self.view addSubview:self.hintLabel];

	self.daemonButton = [self makeButton:@"① 启用后台守护（立即生效）" y:132 color:[UIColor systemBlueColor]];
	[self.daemonButton addTarget:self action:@selector(enableDaemonTapped) forControlEvents:UIControlEventTouchUpInside];

	self.autostartButton = [self makeButton:@"② 设为开机自启（先软安装，重启后试）" y:184 color:[UIColor systemIndigoColor]];
	[self.autostartButton addTarget:self action:@selector(autostartTapped) forControlEvents:UIControlEventTouchUpInside];

	[self makeSmallButton:@"移除自启" x:pad action:@selector(uninstallTapped)];
	[self makeSmallButton:@"刷新" x:pad + 92 action:@selector(refreshTapped)];
	[self makeSmallButton:@"复制状态" x:pad + 172 action:@selector(copyTapped)];
	[self makeSmallButton:@"写系统盘" x:pad + 252 action:@selector(hardInstallTapped)];

	self.rebootButton = [self makeButton:@"立即重启（Kernel Reboot）" y:274 color:[UIColor systemRedColor]];
	[self.rebootButton addTarget:self action:@selector(rebootTapped) forControlEvents:UIControlEventTouchUpInside];

	CGFloat top = 330;
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

- (UIButton *)makeSmallButton:(NSString *)title x:(CGFloat)x action:(SEL)action
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	b.frame = CGRectMake(x, 238, 84, 28);
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

	// 每次打开 App 时，如果守护没在跑就静默拉起一次（不阻塞 UI）
	if (!self.didAutoStart)
	{
		self.didAutoStart = YES;
		if (![TRDaemonStatus()[@"online"] boolValue])
		{
			[self appendLog:@"守护不在线，自动拉起…"];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				int rc = TRLaunchDaemonDetached();
				sleep(1);
				dispatch_async(dispatch_get_main_queue(), ^{
					[self refreshStatus];
					[self appendLog:[NSString stringWithFormat:@"自动拉起 rc=%d，在线=%@", rc,
						[TRDaemonStatus()[@"online"] boolValue] ? @"是" : @"否"]];
				});
			});
		}
	}

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
	[m appendFormat:@"build = TrollReboot 1.5\n"];
	[m appendFormat:@"app uid=%u euid=%u\n", getuid(), geteuid()];

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
	[m appendFormat:@"端点 http://127.0.0.1:8899/reboot\n"];

	NSArray *candidates = TRHelperCandidates();
	[m appendFormat:@"trollstorehelper 候选=%lu\n", (unsigned long)candidates.count];
	for (NSString *c in candidates) [m appendFormat:@"  ✔ %@\n", c];

	[m appendString:@"\n--- install.log 尾部 ---\n"];
	[m appendString:TRInstallLogTail(14)];
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

- (void)autostartTapped
{
	if (self.busy) return;
	self.busy = YES;
	self.autostartButton.enabled = NO;
	[self appendLog:@"--- 设为开机自启 ---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		BOOL wasOnline = [TRDaemonStatus()[@"online"] boolValue];
		NSString *reply = nil;
		int rc;

		// 优先让已经在跑的 root 守护进程自己写 plist（不需要再 spawn 提权）
		if (wasOnline)
		{
			reply = TRDaemonRequest(@"/install");
			rc = 0;
			TRAppendInstallLog([NSString stringWithFormat:@"[app] 通过守护安装：%@", reply ?: @"(无响应)"]);
		}
		else
		{
			rc = TRInstallDaemonViaRoot();
			TRAppendInstallLog([NSString stringWithFormat:@"[app] 守护不在线，走 spawn 安装 rc=%d", rc]);
		}
		sleep(2);

		NSDictionary *st = TRDaemonStatus();
		BOOL online = [st[@"online"] boolValue];
		BOOL libPlist = [st[@"plistExists"] boolValue];
		BOOL systemPlist = [st[@"systemPlistExists"] boolValue];

		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			NSMutableString *msg = [NSMutableString string];
			[msg appendFormat:@"路径=%@ rc=%d 在线=%@ plist(/Library)=%@\n",
				wasOnline ? @"守护(root)" : @"spawn", rc, online ? @"是" : @"否", libPlist ? @"在" : @"无"];
			if (wasOnline && reply.length) [msg appendFormat:@"回复：%@\n", reply];
			if (libPlist) [msg appendString:@"✅ 软安装完成：重启手机后先别打开 App，看自动化是否生效；没起来再点「写系统盘」"];
			else if (systemPlist) [msg appendString:@"⚠️ /System 里已有 plist，重启后看是否自动起来"];
			else [msg appendString:@"❌ 两个位置都没有 plist，请看下面 install.log"];
			[self appendLog:msg];
			self.busy = NO;
			self.autostartButton.enabled = YES;
		});
	});
}

- (void)hardInstallTapped
{
	if (self.busy) return;
	self.busy = YES;
	[self appendLog:@"--- 强制写入系统盘（会尝试重挂根分区）---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		BOOL wasOnline = [TRDaemonStatus()[@"online"] boolValue];
		NSString *reply = nil;
		int rc;

		if (wasOnline)
		{
			reply = TRDaemonRequest(@"/install-hard");
			rc = 0;
		}
		else
		{
			rc = TRInstallDaemonHardViaRoot();
		}
		sleep(2);
		BOOL systemPlist = [TRDaemonStatus()[@"systemPlistExists"] boolValue];

		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			NSMutableString *msg = [NSMutableString string];
			[msg appendFormat:@"路径=%@ rc=%d /System=%@\n", wasOnline ? @"守护(root)" : @"spawn", rc, systemPlist ? @"在" : @"无"];
			if (wasOnline && reply.length) [msg appendFormat:@"回复：%@\n", reply];
			if (systemPlist) [msg appendString:@"✅ /System plist 已写入，重启手机后 launchd 会自己加载"];
			else [msg appendString:@"❌ 系统分区写不进去（只读且重挂失败），改走「打开 URL 自动化」"];
			[self appendLog:msg];
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
