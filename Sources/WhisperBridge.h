#include <stdbool.h>

void *scribe_whisper_open(const char *path, bool use_gpu, const char *backends);
const char *scribe_whisper_run(void *engine, const float *samples, int count);
void scribe_whisper_close(void *engine);
