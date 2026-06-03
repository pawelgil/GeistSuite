#import "ControlSocket.h"
#import "ShimLog.h"

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>
#import <pthread.h>

atomic_int gControlFD = -1;
static pthread_mutex_t gControlLock = PTHREAD_MUTEX_INITIALIZER;

const char *GC_ControlSocketPath(void) {
    static char path[1024];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *env = getenv("GEISTCAST_SOCKET");
        if (env && env[0]) {
            strlcpy(path, env, sizeof(path));
            return;
        }
        // Both sides of the connection derive the path from the same
        // tuple — no handshake. `/tmp/` is the only directory the host
        // and the simulator see at the same filesystem location.
        const char *simUDID = getenv("SIMULATOR_UDID") ?: "";
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *full = [NSString stringWithFormat:@"/tmp/geistcast-%s-%@.sock",
                          simUDID, bundleID];
        strlcpy(path, full.UTF8String, sizeof(path));
    });
    return path;
}

BOOL GC_OpenControlConnection(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        GC_ERR("control: socket() failed errno=%d", errno);
        return NO;
    }
    // Without this, a write to a half-closed socket raises SIGPIPE and
    // kills the host app. The host process can't install a process-wide
    // SIGPIPE handler because we're a dylib injected into a third-party
    // binary, so per-socket SO_NOSIGPIPE is the only safe option.
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = GC_ControlSocketPath();
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        GC_ERR("control: connect(%{public}s) failed errno=%d", path, errno);
        close(fd);
        return NO;
    }
    pthread_mutex_lock(&gControlLock);
    int prev = atomic_exchange(&gControlFD, fd);
    pthread_mutex_unlock(&gControlLock);
    if (prev >= 0) close(prev);
    gc_file_log_enable();
    GC_LOG("control: connected to %{public}s (fd=%d)", path, fd);
    return YES;
}

void GC_WriteControlLine(NSString *jsonLine) {
    NSData *data = [jsonLine dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t remaining = data.length;
    pthread_mutex_lock(&gControlLock);
    int fd = atomic_load(&gControlFD);
    if (fd < 0) {
        pthread_mutex_unlock(&gControlLock);
        return;
    }
    while (remaining > 0) {
        ssize_t n = write(fd, bytes, remaining);
        if (n <= 0) {
            GC_ERR("control: write failed errno=%d", errno);
            close(fd);
            atomic_store(&gControlFD, -1);
            pthread_mutex_unlock(&gControlLock);
            return;
        }
        bytes += n;
        remaining -= (size_t)n;
    }
    pthread_mutex_unlock(&gControlLock);
}

void GC_CloseControlFDIfMatches(int fd) {
    if (fd < 0) return;
    pthread_mutex_lock(&gControlLock);
    if (atomic_load(&gControlFD) == fd) {
        close(fd);
        atomic_store(&gControlFD, -1);
    }
    pthread_mutex_unlock(&gControlLock);
}

NSDictionary *GC_ReadControlMessage(NSMutableData *carryOver) {
    int fd = atomic_load(&gControlFD);
    if (fd < 0) return nil;
    uint8_t buf[4096];
    while (true) {
        while (carryOver.length > 0) {
            const uint8_t *raw = (const uint8_t *)carryOver.bytes;
            NSUInteger newlineIdx = NSNotFound;
            for (NSUInteger i = 0; i < carryOver.length; ++i) {
                if (raw[i] == '\n') { newlineIdx = i; break; }
            }
            if (newlineIdx == NSNotFound) break;
            NSData *line = [carryOver subdataWithRange:NSMakeRange(0, newlineIdx)];
            [carryOver replaceBytesInRange:NSMakeRange(0, newlineIdx + 1)
                                 withBytes:NULL length:0];
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:line
                                                                 options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) return json;
        }
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) return nil;
        [carryOver appendBytes:buf length:(NSUInteger)n];
    }
}
