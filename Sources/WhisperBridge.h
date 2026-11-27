#include <stdbool.h>

void *scribe_whisper_open(const char *path, bool use_gpu, const char *backends);
void *scribe_whisper_channel(void *model);
const char *scribe_whisper_run(void *channel, const float *samples, int count, const char *prompt, int threads);
void scribe_whisper_end_channel(void *channel);
void scribe_whisper_close(void *model);
