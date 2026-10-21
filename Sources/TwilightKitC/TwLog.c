#include "TwilightKitC.h"

#include <stdarg.h>
#include <stdio.h>

static TwLogHandler s_LogHandler;

void TwSetLogHandler(TwLogHandler handler) {
    s_LogHandler = handler;
}

void TwLogMessage(const char* format, ...) {
    char buffer[1024];
    va_list args;

    TwLogHandler handler = s_LogHandler;
    if (handler == NULL) {
        return;
    }

    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);

    handler(buffer);
}

ConnListenerLogMessage TwLogMessageCallback(void) {
    return TwLogMessage;
}
