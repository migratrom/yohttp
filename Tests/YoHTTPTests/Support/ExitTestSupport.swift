#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if os(macOS)
@_silgen_name("__llvm_profile_write_file")
private func writeCoverageProfile() -> Int32
#else
private typealias CoverageWriter = @convention(c) () -> Int32
private let coverageWriter: CoverageWriter? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "__llvm_profile_write_file") else { return nil }
    return unsafeBitCast(symbol, to: CoverageWriter.self)
}()
#endif

private func writeCoverageThenReraise(_ receivedSignal: Int32) {
    #if os(macOS)
    _ = writeCoverageProfile()
    #else
    _ = coverageWriter?()
    #endif
    #if canImport(Darwin)
    Darwin.signal(receivedSignal, SIG_DFL)
    Darwin.raise(receivedSignal)
    #else
    Glibc.signal(receivedSignal, SIG_DFL)
    Glibc.raise(receivedSignal)
    #endif
}

func installCoverageSignalHandlers() {
    #if canImport(Darwin)
    Darwin.signal(SIGTRAP, writeCoverageThenReraise)
    Darwin.signal(SIGILL, writeCoverageThenReraise)
    Darwin.signal(SIGABRT, writeCoverageThenReraise)
    #else
    Glibc.signal(SIGTRAP, writeCoverageThenReraise)
    Glibc.signal(SIGILL, writeCoverageThenReraise)
    Glibc.signal(SIGABRT, writeCoverageThenReraise)
    #endif
}
