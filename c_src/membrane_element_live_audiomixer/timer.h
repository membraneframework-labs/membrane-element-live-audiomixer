#pragma once

#include <stdint.h>
#include <unifex/unifex.h>

typedef struct _timer_state {
  UnifexPid target;
  uint64_t interval;
  uint64_t delay;

  int thread_run; // Flag controlling the thread
  UnifexMutex *lock;
  UnifexTid *thread_id;
} UnifexNifState;

typedef UnifexNifState State;

#include "_generated/timer.h"
