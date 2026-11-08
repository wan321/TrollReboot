#import "RootViewController.h"
#import "TRRootOps.h"
#import "TRDaemon.h"

#include <unistd.h>

@interface RootViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *daemonButton;
@property (nonatomic, strong) UIButton *rebootButton;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UITextView *statusView;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) NSURL *pendingURL;
@end

@implementation RootViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor systemBackgroundColor];
	[self buildUI];
	[self appendLog:[NSString stringWithFormat:@"启动完成 · uid=%u euid=%u\n", getuid(), geteuid()]];
}

- (void)buildUI
{
	CGFloat w = self.view.bounds.size.width;
	CGFloat pad = 16.0;

	self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 56, w - pad * 2, 38)];
	self.titleLabel.text = @"TrollReboot";
	self.titleLabel.font = [UIFont boldSystemFontOfSize:30];
	[self.view addSubview:self.titleLabel];

	self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 94, w - pad * 2, 56)];
	self.hintLabel.numberOfLines = 0;
	self.hintLabel.font = [UIFont systemFontOfSize:12];
	self.hintLabel.textColor = [UIColor secondaryLabelColor];
	self.hintLabel.text = @"锁屏自动触发 = 快捷指令「获取 URL 内容」访问 http://127.0.0.1:8899/reboot（需先启用后台守护）";
	[self.view addSubview:self.hintLabel];

	self.daemonButton = [self makeButton:@"启用后台守护（锁屏可用）" y:154 color:[UIColor systemBlueColor]];
	[self.daemonButton addTarget:self action:@selector(enableDaemonTapped) forControlEvents:UIControlEventTouchUpInside];

	self.rebootButton = [self makeButton:@"立即重启（Kernel Reboot）" y:214 color:[UIColor systemRedColor]];
	[self.rebootButton addTarget:self action:@selector(rebootTapped) forControlEvents:UIControlEventTouchUpInside];

	self.refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
	self.refreshButton.frame = CGRectMake(pad, 276, 120, 28);
	[self.refreshButton setTitle:@"刷新状态" forState:UIControlStateNormal];
	self.refreshButton.titleLabel.font = [UIFont systemFontOfSize:13];
	[self.refreshButton addTarget:self action:@selector(refreshTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:self.refreshButton];

	UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
	copyButton.frame = CGRectMake(pad + 120, 276, 120, 28);
	[copyButton setTitle:@"复制状态" forState:UIControlStateNormal];
	copyButton.titleLabel.font = [UIFont systemFontOfSize:13];
	[copyButton addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:copyButton];

	CGFloat top = 308;
	self.statusView = [[UITextView alloc] initWithFrame:CGRectMake(pad, top, w - pad * 2, self.view.bounds.size.height - top - 24)];
	self.statusView.backgroundColor = [UIColor secondarySystemBackgroundColor];
	self.statusView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
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
	b.frame = CGRectMake(16, y, w - 32, 50);
	b.backgroundColor = color;
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
	b.layer.cornerRadius = 12;
	b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:b];
	return b;
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	[self refreshStatus];
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
	[m appendFormat:@"build = TrollReboot 1.1 (%s %s)\n", __DATE__, __TIME__];
	[m appendFormat:@"app uid=%u euid=%u\n", getuid(), geteuid()];

	NSDictionary *st = TRDaemonStatus();
	NSString *hb = st[@"heartbeat"];
	NSNumber *age = st[@"age"];
	BOOL online = [st[@"online"] boolValue];
	[m appendFormat:@"daemon = %@  在线=%@  plist=%@\n",
		hb.length ? [hb stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]] : @"(无心跳)",
		online ? @"是" : @"否",
		[st[@"plistExists"] boolValue] ? @"在" : @"无"];
	if (age) [m appendFormat:@"心跳年龄 = %@ 秒\n", age];
	[m appendString:@"触发地址 = http://127.0.0.1:8899/reboot\n"];

	NSArray *candidates = TRHelperCandidates();
	[m appendFormat:@"trollstorehelper 候选 = %lu\n", (unsigned long)candidates.count];
	for (NSString *c in candidates) [m appendFormat:@"  ✔ %@\n", c];

	[m appendString:@"\n--- daemon.log 尾部 ---\n"];
	[m appendString:TRDaemonLogTail(10)];
	[m appendString:@"\n--- install.log 尾部 ---\n"];
	[m appendString:TRInstallLogTail(10)];

	self.statusView.text = m;
	NSRange bottom = NSMakeRange(self.statusView.text.length, 0);
	[self.statusView scrollRangeToVisible:bottom];

	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/reboot.log"];
	[fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
	NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
	[[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
}

- (void)appendLog:(NSString *)text
{
	NSMutableString *m = [NSMutableString stringWithString:self.statusView.text ?: @""];
	[m appendFormat:@"%@\n", text];
	self.statusView.text = m;
	NSRange bottom = NSMakeRange(self.statusView.text.length, 0);
	[self.statusView scrollRangeToVisible:bottom];
}

- (void)refreshTapped
{
	[self refreshStatus];
}

- (void)copyTapped
{
	[UIPasteboard generalPasteboard].string = self.statusView.text ?: @"";
}

- (void)enableDaemonTapped
{
	if (self.busy) return;
	self.busy = YES;
	self.daemonButton.enabled = NO;
	[self appendLog:@"--- 启用后台守护 ---"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableString *log = [NSMutableString string];

		int rc = TRInstallDaemonViaRoot();
		[log appendFormat:@"launchd 安装 rc=%d\n", rc];
		sleep(2);

		BOOL online = [TRDaemonStatus()[@"online"] boolValue];
		[log appendFormat:@"安装后在线=%@\n", online ? @"是" : @"否"];

		if (!online)
		{
			int rc2 = TRLaunchDaemonDetached();
			[log appendFormat:@"分离进程启动 rc=%d\n", rc2];
			sleep(2);
			online = [TRDaemonStatus()[@"online"] boolValue];
			[log appendFormat:@"分离后在线=%@\n", online ? @"是" : @"否"];
		}

		[log appendString:online
			? @"✅ 后台守护已就绪：锁屏下用快捷指令「获取 URL 内容」访问 http://127.0.0.1:8899/reboot 即可重启"
			: @"❌ 后台守护没起来，看下面 install.log / daemon.log"];

		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatus];
			[self appendLog:log];
			self.busy = NO;
			self.daemonButton.enabled = YES;
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
