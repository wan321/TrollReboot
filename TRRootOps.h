#import <Foundation/Foundation.h>

/// 扫描 TrollStore 自带 helper 的候选路径（只返回存在的可执行文件）
NSArray<NSString *> *TRHelperCandidates(void);

/// 返回第一个可用的 trollstorehelper，找不到返回 nil
NSString *TRFindTrollStoreHelper(void);

/// 以 root 身份 spawn（persona 覆盖 uid/gid 为 0），返回子进程退出码，spawn 失败返回 errno
int TRSpawnRoot(NSString *path, NSArray<NSString *> *args, NSString **stdOut, NSString **stdErr);

/// 以 root 身份分离启动（不等待子进程，stdio 重定向到 /dev/null），返回 spawn errno
int TRSpawnRootDetached(NSString *path, NSArray<NSString *> *args, NSString **stdOut, NSString **stdErr);

/// 找到 TrollStore 官方 helper 并执行 reboot 子命令；返回是否成功（真重启时本进程已被杀死，走不到返回）
BOOL TRRequestReboot(NSString **log);
