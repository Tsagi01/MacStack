import Darwin
import Foundation

/// 进程启动时需要建立的信号基线。
public enum ProcessSignalBaseline {
    /// 忽略 `SIGPIPE`。
    ///
    /// **默认处置下，向「读端已关闭」的管道写入会让整个进程立即死亡**（信号 13），
    /// 代码里的 `catch` 根本没有机会执行。恢复数据库备份时会踩到：mariadb 客户端在
    /// 批处理模式下**遇错即停**，SQL 有语法错误就退出，而我们还在往它的 stdin 写后续内容。
    ///
    /// 实测确认过：不忽略时进程以 **141**（128 + 13）退出，`catch` 不执行、用户看不到
    /// 任何错误信息；忽略之后同样的写入抛出 `EPIPE`，按普通错误处理即可。
    ///
    /// 忽略 `SIGPIPE` 是任何会与子进程或套接字通信、并且自己处理写入错误的程序的
    /// 通行做法——把「对端没了」当成一次可处理的写入失败，而不是自杀。
    public static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// 让**这一个**文件描述符上的写入在管道断开时返回 `EPIPE`，而不是触发 `SIGPIPE`。
    ///
    /// 与 `ignoreSIGPIPE()` 的区别很重要：这是按 fd 生效的，**不依赖进程级信号处置**。
    /// 也就是说，即使某个入口（新的命令行工具、测试进程）忘了建立基线，这里的写入
    /// 也不会杀死进程。实测 `F_SETNOSIGPIPE` 可用。
    ///
    /// 因此每个「往子进程 stdin 写」的地方都应当调用它——`ignoreSIGPIPE()` 只是兜底，
    /// 覆盖那些我们没想到的写入点，不能替代这一步。
    @discardableResult
    public static func disableSIGPIPE(on handle: FileHandle) -> Bool {
        fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0
    }
}
