#import "ShimLog.h"

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#include <stdatomic.h>

// Each dylib's init unit overrides this with its own subsystem
// (com.geistcast.shim.app / com.geistcast.shim.extension). The weak
// default keeps ShimCore linkable on its own — e.g. for the macOS SPM
// build that compiles ShimCore for unit tests without a dylib in scope.
__attribute__((weak))
os_log_t gc_log(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("com.geistcast.shim", "Shim"); });
    return l;
}

static atomic_bool gShimFileEnabled = false;
static int gShimFd = -1;
static dispatch_once_t gShimFdOnce;

static const char *gc_role(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bid hasSuffix:@".BroadcastExtension"] ? "extension" : "host";
}

void gc_file_log_enable(void) {
    dispatch_once(&gShimFdOnce, ^{
        const char *dir = getenv("GEISTCAST_LOG_DIR");
        if (!dir || !*dir) return;
        char path[1024];
        int n = snprintf(path, sizeof(path), "%s/shim-%s.log", dir, gc_role());
        if (n <= 0 || (size_t)n >= sizeof(path)) return;
        // O_APPEND so concurrent writers across processes interleave
        // atomically at the kernel level for small (<= PIPE_BUF) writes.
        gShimFd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    });
    atomic_store(&gShimFileEnabled, true);
}

// `%{public}@` and `%{public}s` are os_log-only annotations; NSString's
// formatter chokes on them. Strip the privacy modifier before formatting.
static NSString *gc_strip_privacy(const char *fmt) {
    NSMutableString *s = [NSMutableString stringWithUTF8String:fmt];
    NSRange r = NSMakeRange(0, s.length);
    [s replaceOccurrencesOfString:@"%{public}"
                       withString:@"%"
                          options:0
                            range:r];
    r = NSMakeRange(0, s.length);
    [s replaceOccurrencesOfString:@"%{private}"
                       withString:@"%"
                          options:0
                            range:r];
    return s;
}

void gc_file_log_append(const char *level, const char *fmt, ...) {
    if (!atomic_load(&gShimFileEnabled)) return;
    if (gShimFd < 0) return;

    NSString *cleaned = gc_strip_privacy(fmt);
    va_list args;
    va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:cleaned arguments:args];
    va_end(args);

    char ts[32];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    size_t base = strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
    if (base > 0 && base + 5 < sizeof(ts)) {
        snprintf(ts + base, sizeof(ts) - base, ".%03d", (int)(tv.tv_usec / 1000));
    }

    NSString *line = [NSString stringWithFormat:@"[%s] [%s] [pid=%d] %@\n",
                       ts, level, getpid(), message];
    const char *bytes = [line UTF8String];
    if (!bytes) return;
    size_t len = strlen(bytes);
    // Single write() is atomic for len <= PIPE_BUF on Darwin. Cap longer
    // lines to avoid interleaving with other writers' lines.
    if (len > 4096) len = 4096;
    (void)write(gShimFd, bytes, len);
}
