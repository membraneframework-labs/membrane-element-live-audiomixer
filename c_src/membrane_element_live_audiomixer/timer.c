#include "timer.h"
#include <sys/time.h>

static void *timer_thread_fun(void *arg);
static void stop_sender_thread(UnifexNifState *state);
static void shout_like_sleep(uint64_t sleep_time_ms);
static uint64_t shout_like_get_time(void);

void handle_destroy_state(UnifexEnv *env, UnifexNifState *state) {
  UNIFEX_UNUSED(env);
  if (state->thread_id != NULL) {
    // FIXME: This can take a while...
    stop_sender_thread(state);
  }
  unifex_mutex_destroy(state->lock);
}

UNIFEX_TERM start_native_sender(UnifexEnv *env, UnifexPid pid,
                                uint64_t interval, uint64_t delay) {
  UNIFEX_TERM result;
  UnifexNifState *state = unifex_alloc_state(env);
  state->target = pid;
  state->thread_run = 1;
  state->lock = unifex_mutex_create("timer_mutex");
  state->interval = interval;
  state->delay = delay;
  state->thread_id = unifex_alloc(sizeof(UnifexTid));
  int err = unifex_thread_create("timer_thread", state->thread_id,
                                 timer_thread_fun, state);

  if (err != 0) {
    result = start_native_sender_result_error(env, "thread_create");
    goto start_native_sender_exit;
  }

  result = start_native_sender_result_ok(env, state);
start_native_sender_exit:
  unifex_release_state(env, state);
  return result;
}

UNIFEX_TERM stop_native_sender(UnifexEnv *env, UnifexNifState *state) {
  UNIFEX_TERM result;
  if (state->thread_id != NULL) {
    stop_sender_thread(state);
    result = stop_native_sender_result_ok(env);
  } else {
    result = stop_native_sender_result_error_stopped(env);
  }

  unifex_release_state(env, state);
  return result;
}

UNIFEX_TERM native_time(UnifexEnv *env) {
  return native_time_result(env, shout_like_get_time());
}

static void stop_sender_thread(UnifexNifState *state) {
  unifex_mutex_lock(state->lock);
  state->thread_run = 0;
  unifex_mutex_unlock(state->lock);

  unifex_thread_join(*state->thread_id, NULL);

  unifex_free(state->thread_id);
  state->thread_id = NULL;
}

static void shout_like_sleep(uint64_t sleep_time_ms) {
  struct timeval sleeper;

  sleeper.tv_sec = sleep_time_ms / 1000;
  sleeper.tv_usec = (sleep_time_ms % 1000) * 1000;
  select(1, NULL, NULL, NULL, &sleeper);
}

static uint64_t shout_like_get_time(void) {
  struct timeval mtv;

  gettimeofday(&mtv, NULL);

  return (uint64_t)(mtv.tv_sec) * 1000 + (uint64_t)(mtv.tv_usec) / 1000;
}

static void *timer_thread_fun(void *arg) {
  UnifexNifState *state = (UnifexNifState *)arg;
  UnifexEnv *env = unifex_alloc_env();

  uint64_t start_time = shout_like_get_time();
  shout_like_sleep(state->interval);

  uint64_t tick_cnt = 1;
  int should_quit = 0;
  while (!should_quit) {

    tick_cnt += 1;
    uint64_t next_tick_time = start_time + state->interval * tick_cnt;
    int res = send_tick(env, state->target, UNIFEX_FROM_CREATED_THREAD,
                        next_tick_time);
    if (!res) {
      break;
    }

    // In case of extreme system load it is possible to
    // go past the next_tick_time. Substraction in such case would result
    // in unsigned integer underflow causing a VERY long sleep
    uint64_t now = shout_like_get_time();
    if (next_tick_time > now) {
      shout_like_sleep(next_tick_time - now);
    }

    unifex_mutex_lock(state->lock);
    should_quit = !state->thread_run;
    unifex_mutex_unlock(state->lock);
  }
  return NULL;
}
