#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "TRDaemon.h"

#include <string.h>

int main(int argc, char *argv[])
{
	// launchd / root 分离进程直接跑守护逻辑，不初始化 UIKit
	if (argc > 1 && strcmp(argv[1], "--daemon") == 0)
	{
		return TRRunDaemon();
	}
	if (argc > 1 && strcmp(argv[1], "--install-daemon") == 0)
	{
		return TRInstallDaemon();
	}

	@autoreleasepool
	{
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
	}
}
