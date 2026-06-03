#include "SocketIO.h"

#include <unistd.h>

ssize_t GC_ReadAll(int fd, void *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, (char *)buf + got, len - got);
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return (ssize_t)got;
}
