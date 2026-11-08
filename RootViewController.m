#import "RootViewController.h"
#import "TRDaemon.h"
#import "TRBattery.h"
#import "TRMonitor.h"
#import "TRRootOps.h"

#import <sys/sysctl.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#include <unistd.h>
#include <time.h>

/*
 * v3.5-dash：主界面改成电池仪表盘。
 *
 * 打开 App 就自动做两件事（不再需要点按钮）：
 *   1) 后台守护不在跑 → 以 root 分离进程拉起（TREnsureDaemonDetached）
 *   2) 自动开始充电探针（每秒向守护要一次 /batteryjson）
 *
 * 所有需要 root 的动作都在守护里做，App 只负责显示。
 */

#define TR_BUILD_TAG @"TrollReboot 3.5-mon"

static NSString *TRDeviceName(void)
{
	char machine[64] = {0};
	size_t len = sizeof(machine);
	if (sysctlbyname("hw.machine", machine, &len, NULL, 0) != 0 || machine[0] == 0)
		return @"iPhone";

	NSString *m = @(machine);
	if ([m isEqualToString:@"iPhone12,8"])
		return @"iPhone SE2";
	if ([m isEqualToString:@"iPhone12,1"])
		return @"iPhone 11";
	if ([m isEqualToString:@"iPhone11,2"])
		return @"iPhone XS";

	return m;
}

static NSString *TRUptimeText(void)
{
	struct timeval boot = {0};
	size_t len = sizeof(boot);
	if (sysctlbyname("kern.boottime", &boot, &len, NULL, 0) != 0 || boot.tv_sec == 0)
		return @"?";

	long long up = (long long)time(NULL) - (long long)boot.tv_sec;
	if (up < 0)
		up = 0;

	long days = (long)(up / 86400);
	long hours = (long)((up % 86400) / 3600);
	long mins = (long)((up % 3600) / 60);
	return [NSString stringWithFormat:@"%ld天%ld小时%ld分", days, hours, mins];
}

static double TRMemoryUsageMB(void)
{
	mach_port_t host = mach_host_self();
	vm_statistics64_data_t vm = {0};
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
		return -1;

	vm_size_t page = 0;
	host_page_size(host, &page);
	double used = ((double)vm.active_count + (double)vm.wire_count +
	               (double)vm.compressor_page_count) * (double)page;
	return used / (1024.0 * 1024.0);
}

@interface RootViewController ()

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *uptimeLabel;
@property (nonatomic, strong) UIImageView *batteryIcon;
@property (nonatomic, strong) UITextView *infoView;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *clipboardButton;
@property (nonatomic, strong) UIButton *rebootButton;
@property (nonatomic, strong) UIButton *monitorButton;
@property (nonatomic, assign) NSInteger monitorMinutes;
@property (nonatomic, copy) NSString *monitorNote;

@property (nonatomic, strong) NSTimer *probeTimer;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;
@property (nonatomic, assign) NSInteger probeTicks;
@property (nonatomic, assign) NSInteger failStreak;
@property (nonatomic, assign) BOOL didAutoStart;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) NSURL *pendingURL;

@end

@implementation RootViewController

- (void)viewDidLoad
{
	[super viewDidLoad];

	self.view.backgroundColor = [UIColor blackColor];
	self.logLines = [NSMutableArray array];

	CGFloat w = self.view.bounds.size.width;
	CGFloat pad = 16.0;
	CGFloat y = 44.0;

	self.batteryIcon = [[UIImageView alloc] initWithFrame:CGRectMake((w - 150) / 2.0, y, 150, 70)];
	self.batteryIcon.contentMode = UIViewContentModeScaleAspectFit;
	self.batteryIcon.tintColor = [UIColor colorWithRed:0.29 green:0.87 blue:0.31 alpha:1.0];
	[self.view addSubview:self.batteryIcon];
	y += 78;

	self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 26)];
	self.titleLabel.textAlignment = NSTextAlignmentCenter;
	self.titleLabel.textColor = [UIColor whiteColor];
	self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
	self.titleLabel.text = [NSString stringWithFormat:@"%@ (iOS %@)", TRDeviceName(),
	                                                     [[UIDevice currentDevice] systemVersion]];
	[self.view addSubview:self.titleLabel];
	y += 28;

	self.uptimeLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 22)];
	self.uptimeLabel.textAlignment = NSTextAlignmentCenter;
	self.uptimeLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
	self.uptimeLabel.font = [UIFont systemFontOfSize:15];
	self.uptimeLabel.text = [NSString stringWithFormat:@"当前系统已运行：%@", TRUptimeText()];
	[self.view addSubview:self.uptimeLabel];
	y += 32;

	CGFloat buttonsH = 44.0 + 8.0 + 40.0 + 8.0;   // 两按钮行 + 卡死分钟数行
	CGFloat logH = 96.0;
	CGFloat infoH = self.view.bounds.size.height - y - buttonsH - logH - 8 - 20;
	if (infoH < 200)
		infoH = 200;

	self.infoView = [[UITextView alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, infoH)];
	self.infoView.backgroundColor = [UIColor blackColor];
	self.infoView.textColor = [UIColor whiteColor];
	self.infoView.editable = NO;
	self.infoView.selectable = YES;
	self.infoView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
	self.infoView.textContainerInset = UIEdgeInsetsZero;
	self.infoView.text = @"正在读取电池…";
	[self.view addSubview:self.infoView];
	y += infoH + 8;

	CGFloat bw = (w - pad * 2 - 10) / 2.0;
	self.clipboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
	self.clipboardButton.frame = CGRectMake(pad, y, bw, 44);
	[self.clipboardButton setTitle:@"复制状态" forState:UIControlStateNormal];
	self.clipboardButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
	self.clipboardButton.layer.borderColor = [UIColor colorWithRed:0.29 green:0.87 blue:0.31 alpha:1.0].CGColor;
	self.clipboardButton.layer.borderWidth = 1.5;
	self.clipboardButton.layer.cornerRadius = 22;
	[self.clipboardButton addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:self.clipboardButton];

	self.rebootButton = [UIButton buttonWithType:UIButtonTypeSystem];
	self.rebootButton.frame = CGRectMake(pad + bw + 10, y, bw, 44);
	[self.rebootButton setTitle:@"立即重启" forState:UIControlStateNormal];
	[self.rebootButton setTitleColor:[UIColor colorWithRed:1.0 green:0.35 blue:0.31 alpha:1.0]
	                        forState:UIControlStateNormal];
	self.rebootButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
	self.rebootButton.layer.borderColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.31 alpha:1.0].CGColor;
	self.rebootButton.layer.borderWidth = 1.5;
	self.rebootButton.layer.cornerRadius = 22;
	[self.rebootButton addTarget:self action:@selector(rebootTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:self.rebootButton];
	y += 44 + 8;

	// v3.5-mon：唯一的可调项——连续多少分钟算卡死
	self.monitorButton = [UIButton buttonWithType:UIButtonTypeSystem];
	self.monitorButton.frame = CGRectMake(pad, y, w - pad * 2, 40);
	[self.monitorButton setTitle:@"卡死分钟数：5 分钟（点我修改）" forState:UIControlStateNormal];
	[self.monitorButton setTitleColor:[UIColor colorWithWhite:0.92 alpha:1.0] forState:UIControlStateNormal];
	self.monitorButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
	self.monitorButton.layer.borderColor = [UIColor colorWithWhite:0.45 alpha:1.0].CGColor;
	self.monitorButton.layer.borderWidth = 1.0;
	self.monitorButton.layer.cornerRadius = 20;
	[self.monitorButton addTarget:self action:@selector(monitorTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:self.monitorButton];
	y += 40 + 8;

	self.logView = [[UITextView alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, logH)];
	self.logView.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
	self.logView.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
	self.logView.editable = NO;
	self.logView.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
	self.logView.textContainerInset = UIEdgeInsetsMake(4, 4, 4, 4);
	self.logView.layer.cornerRadius = 8;
	[self.view addSubview:self.logView];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];

	self.uptimeLabel.text = [NSString stringWithFormat:@"当前系统已运行：%@", TRUptimeText()];
	[self handlePendingURL];

	// 打开 App 只自动跑一次：起守护 + 开探针
	if (self.didAutoStart)
	{
		[self probeTick];
		return;
	}
	self.didAutoStart = YES;

	[self appendLog:@"打开 App：自动检查后台守护…"];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int rc = TREnsureDaemonDetached();
		sleep(2);
		dispatch_async(dispatch_get_main_queue(), ^{
			RootViewController *s2 = weakSelf;
			if (s2 == nil)
				return;
			BOOL online = [TRDaemonStatus()[@"online"] boolValue];
			[s2 appendLog:online ? [NSString stringWithFormat:@"✅ 后台守护在线（rc=%d）", rc]
			                     : [NSString stringWithFormat:@"⚠️ 守护没起来 rc=%d（看 daemon.log）", rc]];
			[s2 startProbe];
			[s2 reloadMonitor];
		});
	});
}

#pragma mark - 探针（自动运行）

- (void)startProbe
{
	if (self.probeTimer != nil)
		return;

	self.probeTicks = 0;
	self.failStreak = 0;
	[self appendLog:@"自动开始充电探针（每秒一次）"];

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
	[self.probeTimer invalidate];
	self.probeTimer = nil;
}

- (void)probeTick
{
	self.probeTicks++;
	NSInteger tick = self.probeTicks;

	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSDictionary *snap = [weakSelf fetchSnapshot];
		dispatch_async(dispatch_get_main_queue(), ^{
			RootViewController *s2 = weakSelf;
			if (s2 == nil)
				return;
			if (snap == nil)
			{
				s2.failStreak += 1;
				if (s2.failStreak == 3)
					[s2 appendLog:@"⚠️ 连续没拿到电池数据（守护没响应）"];
				if (s2.failStreak >= 10)
				{
					[s2 stopProbe];
					[s2 appendLog:@"探针暂停：守护一直没响应，重开 App 再试"];
				}
				return;
			}
			s2.failStreak = 0;
			[s2 renderSnapshot:snap tick:tick];
		});
	});
}

#pragma mark - 取数据

/// 向守护要一份 JSON 快照；守护是旧版（unknown path）时重启一次再试
- (NSDictionary *)fetchSnapshot
{
	NSString *raw = [self rawRequest:@"/batteryjson"];
	if ([raw isEqualToString:@"unknown path"])
	{
		TRRestartDaemonDetached();
		sleep(2);
		raw = [self rawRequest:@"/batteryjson"];
	}
	if (raw.length == 0 || [raw isEqualToString:@"unknown path"])
		return nil;

	NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
	if (data.length == 0)
		return nil;

	id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
	return [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
}

- (NSString *)rawRequest:(NSString *)path
{
	NSString *body = TRDaemonRequest(path);
	NSString *t = [body ?: @"" stringByTrimmingCharactersInSet:
	               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (t.length == 0 || [t isEqualToString:@"(无响应)"] || [t hasPrefix:@"connect"])
		return @"";
	return t;
}

#pragma mark - 渲染

- (void)renderSnapshot:(NSDictionary *)s tick:(NSInteger)tick
{
	BOOL ok = [s[@"ok"] boolValue];
	NSNumber *pct = s[@"percent"];
	NSNumber *cur = s[@"currentMA"];
	NSNumber *volt = s[@"voltageMV"];
	NSNumber *temp = s[@"tempC"];
	NSNumber *health = s[@"healthPercent"];
	NSNumber *cycles = s[@"cycleCount"];
	NSNumber *design = s[@"designCapacity"];
	NSNumber *rawCap = s[@"rawCapacity"];
	NSNumber *rawMax = s[@"rawMaxCapacity"];
	NSNumber *full = s[@"maxCapacity"];
	NSNumber *power = s[@"powerW"];

	// 大电池图标随电量变化
	NSString *symbol = @"battery.100";
	if (pct)
	{
		NSInteger p = [pct integerValue];
		if (p < 13) symbol = @"battery.0";
		else if (p < 38) symbol = @"battery.25";
		else if (p < 63) symbol = @"battery.50";
		else if (p < 88) symbol = @"battery.75";
	}
	if ([s[@"charging"] boolValue])
		symbol = [symbol stringByAppendingString:@".bolt"];
	if (@available(iOS 13.0, *))
	{
		UIImage *img = [UIImage systemImageNamed:symbol] ?: [UIImage systemImageNamed:@"battery.100"];
		self.batteryIcon.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	}

	if (!ok)
	{
		self.infoView.text = [NSString stringWithFormat:@"读取失败：%@", s[@"error"] ?: @"?"];
		return;
	}

	NSMutableString *m = [NSMutableString string];

	[m appendFormat:@"电池健康状态：%@\n",
		health ? [NSString stringWithFormat:@"%.0f%%", [health doubleValue]] : @"?"];
	[m appendFormat:@"电池循环次数：%@ 次\n",
		cycles ? [NSString stringWithFormat:@"%ld", (long)[cycles integerValue]] : @"?"];
	[m appendFormat:@"电池设计容量：%@ mAh\n",
		design ? [NSString stringWithFormat:@"%ld", (long)[design integerValue]] : @"?"];
	[m appendFormat:@"电池剩余容量：%@ mAh\n",
		rawCap ? [NSString stringWithFormat:@"%ld", (long)[rawCap integerValue]] : @"?"];
	[m appendFormat:@"电池实时容量：%@ mAh\n",
		full ? [NSString stringWithFormat:@"%ld", (long)[full integerValue]] : @"?"];
	[m appendFormat:@"电池预计充电：%@\n",
		[s[@"fullyCharged"] boolValue] ? @"已充满"
		                               : ([s[@"charging"] boolValue] ? @"充电中" : @"未在充电")];
	[m appendFormat:@"电池当前温度：%@\n",
		temp ? [NSString stringWithFormat:@"%.1f℃", [temp doubleValue]] : @"?"];
	[m appendFormat:@"电池当前电压：%@\n",
		volt ? [NSString stringWithFormat:@"%.2fV", [volt doubleValue] / 1000.0] : @"?"];
	[m appendFormat:@"电池当前电流：%@ mA\n",
		cur ? [NSString stringWithFormat:@"%ld", (long)[cur integerValue]] : @"?"];
	[m appendFormat:@"电池当前功率：%@\n",
		power ? [NSString stringWithFormat:@"%.1fW（算值）", [power doubleValue]] : @"?"];
	[m appendFormat:@"电池当前电量：%@\n",
		pct ? [NSString stringWithFormat:@"%ld%%", (long)[pct integerValue]] : @"?"];
	[m appendFormat:@"插电状态：%@\n", [s[@"external"] boolValue] ? @"已连接充电器" : @"未插电"];
	[m appendFormat:@"内存占用估算：%.0f MB\n", TRMemoryUsageMB()];

	NSDictionary *ds = TRDaemonStatus();
	[m appendFormat:@"后台守护：%@", [ds[@"online"] boolValue] ? @"在线 ✅" : @"离线 ❌"];
	if ([ds[@"online"] boolValue])
		[m appendFormat:@"  uid=%@ pid=%@", ds[@"uid"] ?: @"?", ds[@"pid"] ?: @"?"];
	[m appendFormat:@"\n"];
	[m appendFormat:@"探针：运行中（第 %ld 秒）\n", (long)tick];
	[m appendFormat:@"%@\n", TRMonitorVerdict(s)];

	if (rawMax)
		[m appendFormat:@"满容量：%ld mAh\n", (long)[rawMax integerValue]];

	[m appendFormat:@"版本：%@\n", TR_BUILD_TAG];

	self.infoView.text = m;

	// 采样也落盘（fsync），App 被杀也不丢
	if (tick % 5 == 1)
		TRProbeLogAppend([NSString stringWithFormat:@"#%ld %@", (long)tick, TRBatteryLine(s)]);
}

#pragma mark - 卡死分钟数（唯一可配置项）

- (void)reloadMonitor
{
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *text = TRDaemonRequest(@"/monitor");
		NSInteger minutes = 0;
		NSString *note = @"守护未响应";
		if ([text hasPrefix:@"{"])
		{
			NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
			                                                 options:0
			                                                   error:NULL];
			if ([j isKindOfClass:[NSDictionary class]])
			{
				minutes = [j[@"minutes"] integerValue];
				NSString *n = j[@"note"];
				if ([n isKindOfClass:[NSString class]] && n.length > 0)
					note = n;
				else
					note = @"监控运行中";
			}
		}
		if (minutes > 0)
			TRMonitorSetCachedMinutes(minutes);

		dispatch_async(dispatch_get_main_queue(), ^{
			RootViewController *s = weakSelf;
			if (s == nil)
				return;
			s.monitorMinutes = minutes;
			s.monitorNote = note;
			[s updateMonitorButton];
			[s appendLog:[NSString stringWithFormat:@"监控：%@（连续 %ld 分钟算卡死）", note, (long)(minutes > 0 ? minutes : TRMonitorStuckMinutes())]];
		});
	});
}

- (void)updateMonitorButton
{
	NSInteger m = self.monitorMinutes;
	if (m <= 0)
		m = TRMonitorStuckMinutes();
	NSString *title = [NSString stringWithFormat:@"卡死分钟数：%ld 分钟（点我修改）", (long)m];
	[self.monitorButton setTitle:title forState:UIControlStateNormal];
}

- (void)monitorTapped
{
	NSInteger cur = self.monitorMinutes;
	if (cur <= 0)
		cur = TRMonitorStuckMinutes();

	UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"卡死分钟数"
	                                                            message:@"连续这么多分钟电流为 0 且满足其它条件才会重启（1–60）"
	                                                     preferredStyle:UIAlertControllerStyleAlert];
	[ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.text = [NSString stringWithFormat:@"%ld", (long)cur];
		tf.keyboardType = UIKeyboardTypeNumberPad;
		tf.textAlignment = NSTextAlignmentCenter;
	}];
	__weak typeof(self) weakSelf = self;
	[ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	[ac addAction:[UIAlertAction actionWithTitle:@"保存"
	                                       style:UIAlertActionStyleDefault
	                                     handler:^(UIAlertAction *a) {
		                                     NSString *v = ac.textFields.firstObject.text;
		                                     [weakSelf saveMinutes:[v integerValue]];
	                                     }]];
	[self presentViewController:ac animated:YES completion:nil];
}

- (void)saveMinutes:(NSInteger)minutes
{
	if (minutes < TRMON_MINUTES_MIN)
		minutes = TRMON_MINUTES_MIN;
	if (minutes > TRMON_MINUTES_MAX)
		minutes = TRMON_MINUTES_MAX;

	[self appendLog:[NSString stringWithFormat:@"设置卡死分钟数 → %ld", (long)minutes]];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *path = [NSString stringWithFormat:@"/monitor/set?minutes=%ld", (long)minutes];
		NSString *r = TRDaemonRequest(path);
		dispatch_async(dispatch_get_main_queue(), ^{
			RootViewController *s = weakSelf;
			if (s == nil)
				return;
			if ([r hasPrefix:@"{"])
			{
				NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[r dataUsingEncoding:NSUTF8StringEncoding]
				                                                 options:0
				                                                   error:NULL];
				if ([j isKindOfClass:[NSDictionary class]])
					s.monitorMinutes = [j[@"minutes"] integerValue];
			}
			if (s.monitorMinutes <= 0)
				s.monitorMinutes = minutes;
			TRMonitorSetCachedMinutes(s.monitorMinutes);
			[s updateMonitorButton];
			[s appendLog:[NSString stringWithFormat:@"已生效：连续 %ld 分钟卡死才重启", (long)s.monitorMinutes]];
			[s reloadMonitor];
		});
	});
}

#pragma mark - 按钮

- (void)copyTapped
{
	NSString *text = [NSString stringWithFormat:@"%@ %@\n%@\n--- 日志 ---\n%@",
	                                           TRDeviceName(),
	                                           [[UIDevice currentDevice] systemVersion],
	                                           self.infoView.text ?: @"",
	                                           [self.logLines componentsJoinedByString:@"\n"]];
	[UIPasteboard generalPasteboard].string = text;
	[self appendLog:@"已复制到剪贴板"];
}

- (void)rebootTapped
{
	if (self.busy)
		return;
	self.busy = YES;
	[self appendLog:@"请求重启…"];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *rlog = nil;
		BOOL ok = TRRequestReboot(&rlog);
		NSDictionary *r = @{ @"ok": @(ok), @"detail": (rlog ?: @"(无输出)") };
		dispatch_async(dispatch_get_main_queue(), ^{
			RootViewController *s2 = weakSelf;
			[s2 appendLog:[NSString stringWithFormat:@"重启结果：%@", r[@"detail"] ?: @"?"]];
			s2.busy = NO;
		});
	});
}

#pragma mark - URL / 日志

/// 外部（URL scheme）把请求转进来
- (void)handleIncomingURL:(NSURL *)url
{
	self.pendingURL = url;
	if (self.isViewLoaded)
		[self handlePendingURL];
}

- (void)handlePendingURL
{
	if (self.pendingURL == nil)
		return;

	NSURL *u = self.pendingURL;
	self.pendingURL = nil;
	[self appendLog:[NSString stringWithFormat:@"收到 URL：%@", u.absoluteString]];

	NSString *host = u.host ?: @"";
	if ([host isEqualToString:@"reboot"])
		[self rebootTapped];
}

- (void)appendLog:(NSString *)line
{
	time_t now = time(NULL);
	struct tm tmv;
	localtime_r(&now, &tmv);
	char hhmmss[16];
	snprintf(hhmmss, sizeof(hhmmss), "%02d:%02d:%02d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

	[self.logLines addObject:[NSString stringWithFormat:@"[%s] %@", hhmmss, line]];
	if (self.logLines.count > 200)
		[self.logLines removeObjectAtIndex:0];

	self.logView.text = [self.logLines componentsJoinedByString:@"\n"];
	[self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
}

@end
