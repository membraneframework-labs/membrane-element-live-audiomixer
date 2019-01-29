#include "timer.h"
#include <stdint.h>
#include <sys/time.h>

static void * timer_thread_fun(void * arg);

void handle_destroy_state(UnifexEnv *env, UnifexNifState * state) {
  UNIFEX_UNUSED(env);
  printf("destroy\n");
  if (state->thread_id != NULL) {
    unifex_mutex_lock(state->lock);
    state->thread_run = 0;
    unifex_mutex_unlock(state->lock);

    // FIXME: this can take too much time
    unifex_thread_join(*state->thread_id, NULL);
    unifex_free(state->thread_id);
    state->thread_id = NULL;
  }
  unifex_mutex_destroy(state->lock);
}

UNIFEX_TERM start_sender(UnifexEnv* env, UnifexPid pid, unsigned interval, unsigned delay) {
  UNIFEX_TERM result;
  UnifexNifState * state = unifex_alloc_state(env);
  state->target = pid;
  state->thread_run = 1;
  state->lock = unifex_mutex_create("timer_mutex");
  state->interval = interval;
  state->delay = delay;
  state->thread_id = unifex_alloc(sizeof(UnifexTid));
  printf("start\n");
  int err = unifex_thread_create("timer_thread", state->thread_id, timer_thread_fun, state);

  if (err != 0) {
    result = start_sender_result_error(env, "thread_create");
    goto start_sender_exit;
  }

  result = start_sender_result_ok(env, state);
start_sender_exit:
  unifex_release_state(env, state);
  return result;
}

UNIFEX_TERM stop_sender(UnifexEnv* env, UnifexNifState * state) {
  UNIFEX_TERM result;
  if (state->thread_id != NULL) {
    unifex_mutex_lock(state->lock);
    state->thread_run = 0;
    unifex_mutex_unlock(state->lock);

    unifex_free(state->thread_id);
    state->thread_id = NULL;
    result = stop_sender_result_ok(env);
  } else {
    result = stop_sender_result_error_stopped(env);
  }

  unifex_release_state(env, state);
  return result;
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

static void * timer_thread_fun(void * arg) {
  UnifexNifState * state = (UnifexNifState *) arg;
  UnifexEnv *env = unifex_alloc_env();
  shout_like_sleep(state->delay + state->interval);
  uint64_t start_time = shout_like_get_time();
  unsigned tick_cnt = 1;
  int should_quit = 0;
  while(!should_quit) {

    int res = send_tick(env, state->target, UNIFEX_FROM_CREATED_THREAD, tick_cnt);
    if (!res) {
      should_quit = 1;
      continue;
    }
    tick_cnt += 1;
    shout_like_sleep(state->interval * tick_cnt - (shout_like_get_time() - start_time));

    unifex_mutex_lock(state->lock);
    should_quit = !state->thread_run;
    unifex_mutex_unlock(state->lock);
  }
  return NULL;
}

