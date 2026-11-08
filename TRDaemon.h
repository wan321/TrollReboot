#import <Foundation/Foundation.h>

/// 后台守护模式入口（launchd 或 root 分离进程启动，参数 --daemon）
int TRRunDaemon(void);

/// 安装模式入口（必须以 root 运行，参数 --install-daemon）
int TRInstallDaemon(void);

/// 守护进程是否在线（读心跳文件）
NSDictionary<NSString *, id> *TRDaemonStatus(void);

/// 守护进程日志 / 安装日志尾部
NSString *TRDaemonLogTail(NSUInteger lines);
NSString *TRInstallLogTail(NSUInteger lines);

/// 以 root 分离进程方式拉起自身 --daemon（失败返回 errno）
int TRLaunchDaemonDetached(void);

/// 以 root 运行自身 --install-daemon 安装 launchd 常驻任务（返回 exit code，spawn 失败返回 errno）
int TRInstallDaemonViaRoot(void);
