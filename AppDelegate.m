#import "AppDelegate.h"
#import "RootViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	self.root = [[RootViewController alloc] init];
	self.window.rootViewController = self.root;
	[self.window makeKeyAndVisible];

	NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
	if (launchURL)
	{
		[self.root handleIncomingURL:launchURL];
	}
	return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
	[self.root handleIncomingURL:url];
	return YES;
}

@end
