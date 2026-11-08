#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "TRDaemon.h"

#include <string.h>

int main(int argc, char *argv[])
{
	// launchd / root 分离进程直接跑后台逻辑，不初始化 UIKit
	if (argc > 1 && strcmp(argv[1], "--daemon") == 0)
	{
		return TRRunDaemon();
	}
	if (argc > 1 && strcmp(argv[1], "--install-daemon-hard") == 0)
	{
		return TRInstallDaemonHard();
	}

if (argc > 1 && strcmp(argv[1], "--install-daemon") == 0)
	{
		return TRInstallDaemon();
	}
	if (argc > 1 && strcmp(argv[1], "--uninstall-daemon") == 0)
	{
		return TRUninstallDaemon();
	}

	@autoreleasepool
	{
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
	}
}
