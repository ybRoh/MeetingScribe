#include "WhisperBridge.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <whisper.h>
#include <ggml-backend.h>

typedef struct {
    struct whisper_context *model;
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
    struct whisper_context *model = whisper_init_from_file_with_params(path, params);
    if (!model) return NULL;
    Engine *engine = calloc(1, sizeof(Engine));
    if (!engine) {
        whisper_free(model);
        return NULL;
    }
    engine->model = model;
    return engine;
}

const char *scribe_whisper_run(void *opaque, const float *samples, int count) {
    Engine *engine = opaque;
    free(engine->text);
    engine->text = NULL;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language = "ko";
    params.no_context = true;
    params.no_timestamps = true;
    params.print_progress = false;
    params.n_threads = 4;
    if (whisper_full(engine->model, params, samples, count) != 0) return NULL;

    int segments = whisper_full_n_segments(engine->model);
    size_t length = 0;
    for (int i = 0; i < segments; i++) {
        length += strlen(whisper_full_get_segment_text(engine->model, i));
    }
    engine->text = calloc(length + 1, 1);
    if (!engine->text) return NULL;
    char *position = engine->text;
    for (int i = 0; i < segments; i++) {
        const char *text = whisper_full_get_segment_text(engine->model, i);
        size_t size = strlen(text);
        memcpy(position, text, size);
        position += size;
    }
    return engine->text;
}

void scribe_whisper_close(void *opaque) {
    Engine *engine = opaque;
    whisper_free(engine->model);
    free(engine->text);
    free(engine);
}
