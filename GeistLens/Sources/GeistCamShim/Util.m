#import "Util.h"
#import <stdio.h>
#import <strings.h>

static FILE *s_logFile;
static dispatch_once_t s_logFileOnce;
static GeistCamLogLevel s_logThreshold = GeistCamLogInfo;
static dispatch_once_t s_logLevelOnce;

static void initLogLevel(void) {
    dispatch_once(&s_logLevelOnce, ^{
        const char *level = getenv("GEISTCAM_LOG_LEVEL");
        if (!level) return;
        if      (strcasecmp(level, "error") == 0) s_logThreshold = GeistCamLogError;
        else if (strcasecmp(level, "warn")  == 0) s_logThreshold = GeistCamLogWarn;
        else if (strcasecmp(level, "info")  == 0) s_logThreshold = GeistCamLogInfo;
        else if (strcasecmp(level, "debug") == 0) s_logThreshold = GeistCamLogDebug;
    });
}

static void emitLine(GeistCamLogLevel level, const char *msg) {
    initLogLevel();
    if (level > s_logThreshold) return;
    dispatch_once(&s_logFileOnce, ^{
        const char *path = getenv("GEISTCAM_LOG");
        if (path && *path) {
            s_logFile = fopen(path, "a");
            if (s_logFile) setvbuf(s_logFile, NULL, _IOLBF, 0);
        }
    });
    if (s_logFile) {
        time_t t = time(NULL);
        fprintf(s_logFile, "[%ld] %s\n", (long)t, msg);
    }
    fprintf(stderr, "[GeistCamShim] %s\n", msg);
}

void geistcam_marker(const char *msg) {
    emitLine(GeistCamLogInfo, msg);
}

static void emitFormatted(GeistCamLogLevel level, const char *fmt, va_list args) {
    initLogLevel();
    if (level > s_logThreshold) return;
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, args);
    emitLine(level, buf);
}

void geistcam_markerf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    emitFormatted(GeistCamLogInfo, fmt, args);
    va_end(args);
}

void geistcam_warnf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    emitFormatted(GeistCamLogWarn, fmt, args);
    va_end(args);
}

void geistcam_debugf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    emitFormatted(GeistCamLogDebug, fmt, args);
    va_end(args);
}

void swizzleMethod(NSString *className, SEL selector, IMP replacement, IMP *origOut) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, selector);
    if (!m) return;
    IMP orig = method_setImplementation(m, replacement);
    if (origOut) *origOut = orig;
    geistcam_markerf("swizzled -[%s %s]", className.UTF8String, sel_getName(selector));
}
