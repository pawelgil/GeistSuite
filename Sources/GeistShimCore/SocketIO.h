#pragma once

#include <sys/types.h>
#include <stddef.h>

ssize_t GC_ReadAll(int fd, void *buf, size_t len);
