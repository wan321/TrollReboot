#import <Foundation/Foundation.h>

/// 后台守护模式入口（launchd 或 root 分离进程启动，参数 --daemon）
int TRRunDaemon(void);

/// 安装模式入口（必须以 root 运行，参数 --install-daemon）
int TRInstallDaemon(void);

/// 卸载模式入口（必须以 root 运行，参数 --uninstall-daemon）
int TRUninstallDaemon(void);

/// 守护进程是否在线（读心跳文件）
NSDictionary<NSString *, id> *TRDaemonStatus(void);

/// 守护进程日志 / 安装日志尾部
NSString *TRDaemonLogTail(NSUInteger lines);
NSString *TRInstallLogTail(NSUInteger lines);

/// 以 root 分离进程方式拉起自身 --daemon（失败返回 errno）
void TRAppendInstallLog(NSString *text);

NSString *TRDaemonRequest(NSString *path);

int TRLaunchDaemonDetached(void);

/// 以 root 运行自身 --install-daemon 安装 launchd 常驻任务
int TRInstallDaemonHard(void);

/// 以 root 运行自身 --install-daemon-hard（重挂根分区写 /System）
int TRInstallDaemonHardViaRoot(void);

int TRInstallDaemonViaRoot(void);

/// 以 root 运行自身 --uninstall-daemon 卸载 launchd 常驻任务
int TRUninstallDaemonViaRoot(void);

/// 诊断：挂载表 + 关键路径可写探测
NSString *TRPathsProbe(void);

/// 诊断：枚举可替换的系统 App（/private/var/containers）与巨魔持久化助手占用情况
NSString *TRSystemAppsProbe(void);

#pragma mark - v3.1 开机启动器（TrollStore 持久化助手式）

/// 当前进程是否以「被系统当作别家 App 拉起」的启动器身份运行
BOOL TRIsLauncherHost(void);

/// 启动器入口：先起 root 守护，再把控制权交还原 App
int TRRunLauncher(int argc, char *argv[]);

/// --install-launcher（root）：把自身装成 com.apple.tips 的主可执行文件，原件改名备份
int TRInstallLauncher(void);

/// --uninstall-launcher（root）：用备份还原 Tips 原件，删除标记
int TRUninstallLauncher(void);

/// App 内按钮调用：以 root 装 / 还原启动器
int TRLauncherInstallViaRoot(void);
int TRLauncherUninstallViaRoot(void);

/// 是否已有宿主装上了我们的启动器（任一候选宿主带标记即为 YES）
BOOL TRLauncherIsInstalled(void);

/// 启动器状态文本（面板显示用）
NSString *TRLauncherStatusText(void);

/// 启动器日志尾部
NSString *TRLauncherLogTail(NSUInteger lines);
