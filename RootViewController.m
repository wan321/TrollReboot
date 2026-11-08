#import "RootViewController.h"
#import "TRRootOps.h"

#include <unistd.h>

@interface RootViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *rebootButton;
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
	CGFloat pad = 18.0;

	self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 64, w - pad * 2, 40)];
	self.titleLabel.text = @"TrollReboot";
	self.titleLabel.font = [UIFont boldSystemFontOfSize:32];
	[self.view addSubview:self.titleLabel];

	self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 106, w - pad * 2, 54)];
	self.hintLabel.numberOfLines = 0;
	self.hintLabel.font = [UIFont systemFontOfSize:12];
	self.hintLabel.textColor = [UIColor secondaryLabelColor];
	self.hintLabel.text = @"通过 TrollStore 官方 trollstorehelper 以 root 执行 reboot。\n快捷指令：打开 URL → trollreboot://reboot";
	[self.view addSubview:self.hintLabel];

	self.rebootButton = [UIButton buttonWithType:UIButtonTypeSystem];
	self.rebootButton.frame = CGRectMake(pad, 172, w - pad * 2, 56);
	self.rebootButton.backgroundColor = [UIColor systemRedColor];
	[self.rebootButton setTitle:@"立即重启（Kernel Reboot）" forState:UIControlStateNormal];
	[self.rebootButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	self.rebootButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
	self.rebootButton.layer.cornerRadius = 12;
	self.rebootButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.rebootButton addTarget:self action:@selector(rebootTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:self.rebootButton];

	UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
	copyButton.frame = CGRectMake(pad, 236, 110, 30);
	[copyButton setTitle:@"复制状态" forState:UIControlStateNormal];
	copyButton.titleLabel.font = [UIFont systemFontOfSize:13];
	[copyButton addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:copyButton];

	self.statusView = [[UITextView alloc] initWithFrame:CGRectMake(pad, 270, w - pad * 2, 380)];
	self.statusView.backgroundColor = [UIColor secondarySystemBackgroundColor];
	self.statusView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	self.statusView.editable = NO;
	self.statusView.selectable = YES;
	self.statusView.layer.cornerRadius = 10;
	self.statusView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
	self.statusView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self.view addSubview:self.statusView];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	[self refreshStaticInfo];
	if (self.pendingURL)
	{
		NSURL *url = self.pendingURL;
		self.pendingURL = nil;
		[self handleIncomingURL:url];
	}
}

- (void)refreshStaticInfo
{
	NSMutableString *m = [NSMutableString string];
	[m appendFormat:@"build = TrollReboot 1.0 (%s %s)\n", __DATE__, __TIME__];
	[m appendFormat:@"uid=%u euid=%u\n", getuid(), geteuid()];

	NSArray<NSString *> *candidates = TRHelperCandidates();
	[m appendFormat:@"helper 候选数 = %lu\n", (unsigned long)candidates.count];
	for (NSString *c in candidates)
	{
		[m appendFormat:@"  ✔ %@\n", c];
	}
	if (candidates.count == 0)
	{
		[m appendString:@"  ✘ 一个都没找到（TrollStore 路径异常）\n"];
	}
	[self appendLog:m];
}

- (void)appendLog:(NSString *)text
{
	NSString *current = self.statusView.text ?: @"";
	self.statusView.text = [current stringByAppendingFormat:@"%@\n", text];
	NSRange bottom = NSMakeRange(self.statusView.text.length, 0);
	[self.statusView scrollRangeToVisible:bottom];

	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/reboot.log"];
	[fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
	NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], text];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	if ([fm fileExistsAtPath:path])
	{
		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
		[fh seekToEndOfFile];
		[fh writeData:data];
		[fh closeFile];
	}
	else
	{
		[data writeToFile:path atomically:YES];
	}
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
			[self appendLog:@"若设备已在重启，以上内容会随进程消失而丢失；没重启才是证据。"];
			self.busy = NO;
			self.rebootButton.enabled = YES;
		});
	});
}

- (void)copyTapped
{
	[UIPasteboard generalPasteboard].string = self.statusView.text ?: @"";
}

- (void)handleIncomingURL:(NSURL *)url
{
	// 冷启动时 URL 会在 viewDidLoad 之前送到，先存起来
	if (!self.isViewLoaded)
	{
		self.pendingURL = url;
		return;
	}

	NSString *scheme = url.scheme.lowercaseString;
	NSString *host = url.host.lowercaseString;
	[self appendLog:[NSString stringWithFormat:@"收到 URL: %@", url.absoluteString]];

	BOOL schemeOK = [scheme isEqualToString:@"trollreboot"] || [scheme isEqualToString:@"reboottools"];
	BOOL actionOK = host.length == 0 || [host isEqualToString:@"reboot"] || [host isEqualToString:@"kernel"];

	if (!schemeOK || !actionOK)
	{
		[self appendLog:[NSString stringWithFormat:@"忽略：scheme=%@ host=%@", scheme, host]];
		return;
	}
	[self rebootTapped];
}

@end
