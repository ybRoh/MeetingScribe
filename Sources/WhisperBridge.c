#include "WhisperBridge.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <whisper.h>
#include <ggml-backend.h>

typedef struct {
    struct whisper_context *model;
    struct whisper_state *state;
    char *text;
} Engine;

static void discard_log(enum ggml_log_level level, const char *message, void *context) {
    (void) level;
    (void) message;
    (void) context;
}

void *scribe_whisper_open(const char *path, bool use_gpu, const char *backends) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static bool initialized = false;
    pthread_mutex_lock(&lock);
    if (!initialized) {
        ggml_backend_load_all_from_path(backends ? backends : SCRIBE_GGML_BACKENDS);
        whisper_log_set(discard_log, NULL);
        initialized = true;
    }
    pthread_mutex_unlock(&lock);
    if (!ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)) return NULL;
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = use_gpu && ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    return whisper_init_from_file_with_params_no_state(path, params);
}

void *scribe_whisper_channel(void *model) {
    Engine *channel = calloc(1, sizeof(Engine));
    if (!channel) return NULL;
    channel->model = model;
    channel->state = whisper_init_state(model);
    if (!channel->state) {
        free(channel);
        return NULL;
    }
    return channel;
}

const char *scribe_whisper_run(void *opaque, const float *samples, int count, const char *prompt, int threads) {
    Engine *engine = opaque;
    free(engine->text);
    engine->text = NULL;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language = "ko";
    params.no_context = true;
    params.initial_prompt = prompt && *prompt ? prompt : NULL;
    params.no_speech_thold = 0.5f;
    params.no_timestamps = true;
    params.print_progress = false;
    params.n_threads = threads > 0 ? threads : 4;
    if (whisper_full_with_state(engine->model, engine->state, params, samples, count) != 0) return NULL;

    int segments = whisper_full_n_segments_from_state(engine->state);
    size_t length = 0;
    for (int i = 0; i < segments; i++) {
        length += strlen(whisper_full_get_segment_text_from_state(engine->state, i));
    }
    engine->text = calloc(length + 1, 1);
    if (!engine->text) return NULL;
    char *position = engine->text;
    for (int i = 0; i < segments; i++) {
        const char *text = whisper_full_get_segment_text_from_state(engine->state, i);
        size_t size = strlen(text);
        memcpy(position, text, size);
        position += size;
    }
    return engine->text;
}

void scribe_whisper_end_channel(void *opaque) {
    Engine *engine = opaque;
    whisper_free_state(engine->state);
    free(engine->text);
    free(engine);
}

void scribe_whisper_close(void *model) {
    whisper_free(model);
}
