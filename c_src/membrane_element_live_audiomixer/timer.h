#pragma once

#include <unifex/unifex.h>

typedef struct _timer_state {
  UnifexPid target;
  unsigned interval;
  unsigned delay;

  int thread_run;  // Flag controlling the thread
  UnifexMutex *lock;
  UnifexTid * thread_id;
} UnifexNifState;

typedef UnifexNifState State;

#include "_generated/timer.h"
